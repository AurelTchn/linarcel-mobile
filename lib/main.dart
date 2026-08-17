import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:linarcel/app_toast.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:background_fetch/background_fetch.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';

// Configuration API - MODIFIEZ ICI UNIQUEMENT
const String API_BASE_URL = 'https://detection-fraude-python.onrender.com';
// const String API_BASE_URL = 'http://192.168.1.234:8000';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialiser le service de fond
  try {
    await initializeService();
  } catch (e) {
    debugPrint('⚠️ Initialisation du service de fond impossible: $e');
  }

  runApp(const LinarcelApp());
}

Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: true,
      isForegroundMode: true,
      autoStartOnBoot:
          true, // <-- CRUCIAL : Relance le service dès que le téléphone
      notificationChannelId: 'linarcel_location_channel',
      initialNotificationTitle: 'Linarcel - App mobile',
      initialNotificationContent:
          'Vous êtes connecté en tant que Vendeur Motorisé.',
      foregroundServiceNotificationId: 888,
      foregroundServiceTypes: [AndroidForegroundType.location],
    ),
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );

  service.startService();
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  return true;
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  if (service is AndroidServiceInstance) {
    service.setAsForegroundService();
    service.setForegroundNotificationInfo(
      title: "Linarcel - App mobile",
      content: "Suivi GPS en cours...",
    );
  }

  // Fonction interne pour démarrer si credentials existent
  Future<void> tryStartTracking() async {
    final prefs = await SharedPreferences.getInstance();
    final shouldTrack = prefs.getBool('should_track') ?? false;
    _currentToken = prefs.getString('token');
    _currentVmId = prefs.getString('vm_id');

    if (shouldTrack &&
        _currentToken != null &&
        _currentVmId != null &&
        !_isTracking) {
      print('🟢 Service redémarré - reprise du tracking');
      startRealtimeTracking();
      service.invoke('trackingStarted');
    }
  }

  // Démarrer immédiatement si le service est relancé par Android
  await tryStartTracking();

  // Écouter la commande depuis l'UI
  service.on('startTracking').listen((event) async {
    // Mettre à jour le token dans le service même si tracking déjà actif
    if (event != null && event['token'] != null) {
      _currentToken = event['token'];
      _currentVmId = event['vm_id'];
      print('🔄 Token mis à jour dans le service');
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('should_track', true);
    if (_currentToken != null) {
      await prefs.setString('token', _currentToken!);
      await prefs.setString('vm_id', _currentVmId!);
    }

    // Démarrer le stream seulement s'il n'est pas déjà actif
    if (_currentToken != null && _currentVmId != null && !_isTracking) {
      print('🟢 Service redémarré - reprise du tracking');
      startRealtimeTracking();
      service.invoke('trackingStarted');
    }
  });

  service.on('stop').listen((event) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('should_track', false);
    stopRealtimeTracking();
    service.stopSelf();
  });
}

// Variables globales pour le suivi
StreamSubscription<Position>? _positionStreamSubscription;
bool _isTracking = false;
String? _currentToken;
String? _currentVmId;

// Démarrer le suivi en temps réel
Position? _lastSentPosition;
DateTime? _lastSentTime;

void startRealtimeTracking() {
  if (_isTracking) return;

  print('🟢 Démarrage du suivi en temps réel...');

  late final LocationSettings locationSettings;

  if (defaultTargetPlatform == TargetPlatform.android) {
    locationSettings = AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 30, // Filtre matériel de base
    );
  } else {
    locationSettings = const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 30,
    );
  }

  _isTracking = true;

  _positionStreamSubscription =
      Geolocator.getPositionStream(locationSettings: locationSettings).listen(
        (Position position) {
          final now = DateTime.now();

          // 1. Protection Temps : Pas plus d'une requête toutes les 10 secondes
          if (_lastSentTime != null &&
              now.difference(_lastSentTime!).inSeconds < 20) {
            print('⏳ Position ignorée (trop fréquente)');
            return;
          }

          // 2. Protection Distance : Calculer la distance réelle entre la nouvelle et l'ancienne position
          if (_lastSentPosition != null) {
            double distanceInMeters = Geolocator.distanceBetween(
              _lastSentPosition!.latitude,
              _lastSentPosition!.longitude,
              position.latitude,
              position.longitude,
            );

            if (distanceInMeters < 30) {
              print('📏 Déplacement trop court ($distanceInMeters m), ignoré.');
              return;
            }
          }

          // Si on passe les filtres, on met à jour nos variables et on envoie
          _lastSentPosition = position;
          _lastSentTime = now;

          print(
            '📍 Nouvelle position validée: ${position.latitude}, ${position.longitude}',
          );
          _sendLocationToBackend(position);
        },
        onError: (error) {
          print('❌ Erreur de localisation: $error');
        },
      );
}

// Arrêter le suivi
void stopRealtimeTracking() {
  if (!_isTracking) return;

  print('🔴 Arrêt du suivi en temps réel...');
  _positionStreamSubscription?.cancel();
  _positionStreamSubscription = null;
  _isTracking = false;
}

// Envoyer la position au backend
Future<void> _sendLocationToBackend(Position position) async {
  try {
    // Utilise directement les variables du service (même isolate)
    final token = _currentToken;
    final vmId = _currentVmId;

    if (token == null || vmId == null) {
      print('⚠️ Token ou VM ID manquant dans SharedPreferences');
      return;
    }

    final response = await http.post(
      Uri.parse('$API_BASE_URL/api/localisation'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'vm_id': int.parse(vmId),
        'latitude': position.latitude,
        'longitude': position.longitude,
        'precision_meters': position.accuracy,
        'vitesse': position.speed,
        'timestamp': DateTime.now().toIso8601String(),
        'token': token,
      }),
    );

    if (response.statusCode == 200) {
      print('✅ Position envoyée avec succès');
    } else {
      print(
        '${token} ❌ Erreur envoi position: ${response.statusCode} - ${response.body}',
      );
    }
  } catch (e) {
    print('❌ Erreur: $e');
  }
}

// Fonction pour demander les permissions et démarrer le suivi
Future<bool> requestLocationPermissionAndStartTracking() async {
  try {
    // Vérifier les permissions
    LocationPermission permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        print('❌ Permission refusée par l\'utilisateur');
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      print('❌ Permission refusée définitivement');
      return false;
    }

    // Permission accordée - démarrer le suivi
    print('✅ Permission de localisation accordée');

    // Démarrer le service de fond
    final service = FlutterBackgroundService();
    service.startService();

    // Démarrer le suivi
    //startRealtimeTracking();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('should_track', true); // ← AJOUTE ÇA
    service.invoke('startTracking', {
      'token': _currentToken,
      'vm_id': _currentVmId,
    });

    // Envoyer une première position immédiatement
    try {
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      print(
        '📍 Position initiale: ${position.latitude}, ${position.longitude}',
      );
      //_sendLocationToBackend(position);
    } catch (e) {
      print('⚠️ Erreur position initiale: $e');
    }

    return true;
  } catch (e) {
    print('❌ Erreur lors de la demande de permission: $e');
    return false;
  }
}

class LinarcelApp extends StatelessWidget {
  const LinarcelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Linarcel',
      theme: ThemeData(
        primaryColor: const Color(0xFF233360),
        colorScheme: const ColorScheme.light(
          primary: Color(0xFF233360),
          secondary: Color(0xFFea5429),
        ),
        fontFamily: 'Poppins',
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Color(0xFF233360),
          elevation: 0,
          centerTitle: true,
        ),
      ),
      home: const SessionGate(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class SessionGate extends StatefulWidget {
  const SessionGate({super.key});

  @override
  State<SessionGate> createState() => _SessionGateState();
}

class _SessionGateState extends State<SessionGate> {
  bool? _isLoggedIn;

  @override
  void initState() {
    super.initState();
    _checkSession();
  }

  Future<void> _checkSession() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');
    _currentToken = token;
    _currentVmId = prefs.getString('vm_id');
    if (mounted) {
      setState(() => _isLoggedIn = token != null);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoggedIn == null) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFea5429)),
          ),
        ),
      );
    }
    return _isLoggedIn! ? const HomePage() : const LoginPage();
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController _numeroController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _isLoggedIn = false;
  bool _obscurePassword = true;

  @override
  Widget build(BuildContext context) {
    if (_isLoggedIn) {
      return const HomePage();
    }

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF233360), Color(0xFFea5429)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Logo
                  Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(60),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.15),
                          blurRadius: 20,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(14.0),
                      child: Image.asset(
                        'assets/logo-full.png',
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Linarcel',
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Espace Vendeur Motorisé',
                    style: TextStyle(fontSize: 14, color: Colors.white70),
                  ),
                  const SizedBox(height: 48),
                  // Formulaire
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.1),
                          blurRadius: 20,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        children: [
                          // Champ Numéro
                          TextField(
                            controller: _numeroController,
                            style: const TextStyle(fontSize: 16),
                            decoration: InputDecoration(
                              labelText: 'Numéro VM',
                              labelStyle: const TextStyle(
                                color: Color(0xFF233360),
                              ),
                              prefixIcon: const Icon(
                                Icons.phone_android,
                                color: Color(0xFFea5429),
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(
                                  color: Colors.grey,
                                  width: 1,
                                ),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(
                                  color: Colors.grey,
                                  width: 1,
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(
                                  color: Color(0xFFea5429),
                                  width: 2,
                                ),
                              ),
                            ),
                            keyboardType: TextInputType.phone,
                          ),
                          const SizedBox(height: 16),
                          // Champ Mot de passe
                          TextField(
                            controller: _passwordController,
                            obscureText: _obscurePassword,
                            style: const TextStyle(fontSize: 16),
                            decoration: InputDecoration(
                              labelText: 'Mot de passe',
                              labelStyle: const TextStyle(
                                color: Color(0xFF233360),
                              ),
                              prefixIcon: const Icon(
                                Icons.lock,
                                color: Color(0xFFea5429),
                              ),
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _obscurePassword
                                      ? Icons.visibility_off
                                      : Icons.visibility,
                                  color: Colors.grey,
                                ),
                                onPressed: () {
                                  setState(() {
                                    _obscurePassword = !_obscurePassword;
                                  });
                                },
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(
                                  color: Colors.grey,
                                  width: 1,
                                ),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(
                                  color: Colors.grey,
                                  width: 1,
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(
                                  color: Color(0xFFea5429),
                                  width: 2,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 32),
                          // Bouton Connexion
                          _isLoading
                              ? Center(
                                  child: Container(
                                    width: double.infinity,
                                    height: 52,
                                    decoration: BoxDecoration(
                                      color: const Color(
                                        0xFF233360,
                                      ).withOpacity(0.5), // Même couleur bleue que le bouton
                                      borderRadius: BorderRadius.circular(
                                        12,
                                      ), // Même arrondi
                                      boxShadow: const [
                                        BoxShadow(
                                          color: Colors.black12,
                                          blurRadius: 2,
                                          offset: Offset(
                                            0,
                                            2,
                                          ), // Même effet d'élévation
                                        ),
                                      ],
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        SizedBox(
                                          width: 24,
                                          height: 24,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2.5,
                                            valueColor:
                                                AlwaysStoppedAnimation<Color>(
                                                  Color(
                                                    0xFFea5429,
                                                  ), // Votre couleur orange
                                                ),
                                          ),
                                        ),
                                        const SizedBox(width: 16),
                                        const Text(
                                          'Connexion...',
                                          style: TextStyle(
                                            color: Colors
                                                .white, // Texte en blanc pour être lisible sur le bleu
                                            fontSize: 16,
                                            fontWeight: FontWeight
                                                .w600, // Même épaisseur que le bouton
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                              : SizedBox(
                                  width: double.infinity,
                                  height: 52,
                                  child: ElevatedButton(
                                    onPressed: _login,
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF233360),
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      elevation: 2,
                                    ),
                                    child: const Text(
                                      'Se connecter',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Application sécurisée - Support Linarcel',
                    style: TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _login() async {
    try {
      final numero = _numeroController.text.trim();
      final password = _passwordController.text.trim();

      if (numero.isEmpty || password.isEmpty) {
        AppToast.showError(
          context,
          title: 'Champs requis',
          description: 'Veuillez remplir votre numéro et votre mot de passe.',
        );
        return;
      }

      setState(() => _isLoading = true);

      final response = await http.post(
        Uri.parse('$API_BASE_URL/api/login'),
        body: jsonEncode({'numero': numero, 'password': password}),
        headers: {'Content-Type': 'application/json'},
      );

      setState(() => _isLoading = false);
      print("Response backend: ${response.body}");
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('token', data['token']);
        await prefs.setString('vm_id', data['vm_id'].toString());
        await prefs.setString('numero', numero);
        await prefs.setString('nom', data['nom']);

        // Stocker les variables globales pour le suivi
        _currentToken = data['token'];
        _currentVmId = data['vm_id'].toString();

        // Naviguer vers la page d'accueil
        setState(() => _isLoggedIn = true);

        if (mounted) {
          AppToast.showSuccess(
            context,
            title: 'Connexion réussie',
            description: 'Bienvenue, ${data['nom']} !',
          );
        }
      } else {
        if (mounted) {
          AppToast.showError(
            context,
            title: 'Erreur de connexion',
            description: 'Vérifiez votre numéro et mot de passe',
          );
        }
      }
    } catch (e) {
      print('Erreur: $e');
      setState(() => _isLoading = false);
      AppToast.showError(
        context,
        title: 'Erreur de connexion',
        description: 'Une erreur est survenue. Veuillez réessayer.',
      );
      return;
    }
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _vmNumero = '';
  String _vmNom = '';
  String _currentTime = '';
  Timer? _timer;
  bool _isLoggedIn = true;
  bool _isTrackingActive = false;
  bool _isLocationLoading = false;

  @override
  void initState() {
    super.initState();
    _loadVmInfo();
    _updateTime();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _updateTime();
    });

    FlutterBackgroundService().on('trackingStarted').listen((event) {
      if (mounted) setState(() => _isTrackingActive = true);
    });

    // Démarrer le suivi après un court délai pour que l'UI soit chargée
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startLocationTracking();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _updateTime() {
    setState(() {
      _currentTime = _formatDate(DateTime.now());
    });
  }

  String _formatDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year} - ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _loadVmInfo() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _vmNumero = prefs.getString('numero') ?? 'Inconnu';
      _vmNom = prefs.getString('nom') ?? 'Vendeur';
    });
  }

  Future<void> _startLocationTracking() async {
    if (_isTrackingActive) return;

    setState(() => _isLocationLoading = true);

    bool success = await requestLocationPermissionAndStartTracking();

    setState(() {
      _isLocationLoading = false;
      //_isTrackingActive = success;
    });

    if (success && mounted) {
      // AppToast.showSuccess(
      //   context,
      //   title: 'Suivi activé',
      //   description: 'Votre position est envoyée en temps réel',
      // );
    } else if (mounted) {
      AppToast.showError(
        context,
        title: 'Erreur',
        description: 'Veuillez autoriser l\'accès !',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: AppBar(
        title: const Text(
          'Espace vendeur motorisé',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: Color(0xFF233360),
          ),
        ),
        centerTitle: true,
        backgroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout, color: Color(0xFFea5429)),
            onPressed: _logout,
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            // Header avec gradient
            Container(
              width: double.infinity,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF233360), Color(0xFFea5429)],
                ),
                borderRadius: BorderRadius.only(
                  bottomLeft: Radius.circular(30),
                  bottomRight: Radius.circular(30),
                ),
              ),
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 60,
                        height: 60,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(30),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.1),
                              blurRadius: 10,
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(30),
                          child: Container(
                            color: const Color(0xFFF1F5F9),
                            padding: const EdgeInsets.all(8.0),
                            child: const Icon(
                              Icons.person_rounded,
                              color: Color(0xFF475569),
                              size: 32,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _vmNom,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _vmNumero,
                              style: const TextStyle(
                                fontSize: 14,
                                color: Colors.white70,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                color: Colors.green,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Text(
                              'Connecté',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            // Section Information
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                children: [
                  // Carte d'information principale
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.grey.withOpacity(0.1),
                          blurRadius: 10,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: const Color(
                                    0xFF233360,
                                  ).withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Icon(
                                  Icons.verified_user,
                                  color: Color(0xFF233360),
                                  size: 24,
                                ),
                              ),
                              const SizedBox(width: 16),
                              const Expanded(
                                child: Text(
                                  'Bienvenue sur l\'application Linarcel',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF233360),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'Cette application vous permet de rester connecté en permanence à la plateforme centrale Linarcel et de bénéficier de l\'ensemble de nos fonctionnalités dédiées aux Vendeurs Motorisés. Grâce à cette liaison active, votre terminal synchronise automatiquement votre statut de disponibilité, optimise la gestion de vos secteurs de distribution et assure une communication fluide avec la centrale. Gardez l\'application active durant votre parcours pour garantir la continuité de vos services, maximiser vos indicateurs de performance commerciale et bénéficier de l\'assistance prioritaire de nos équipes logistiques en cas de besoin sur le terrain.',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey,
                              height: 1.4,
                            ),
                          ),
                          const SizedBox(height: 16),
                          const Divider(),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              const Icon(
                                Icons.access_time,
                                size: 16,
                                color: Colors.grey,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Dernière connexion: $_currentTime',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.grey.withOpacity(0.1),
              blurRadius: 10,
              offset: const Offset(0, -5),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: _isTrackingActive ? Colors.green : Colors.grey,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _isTrackingActive ? 'Connecté' : 'Login',
              style: TextStyle(
                fontSize: 12,
                color: _isTrackingActive ? Colors.green : Colors.grey,
              ),
            ),
            const SizedBox(width: 16),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: const Color(0xFFea5429),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              'Linarcel',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _logout() async {
    // Afficher le popup de confirmation
    final bool? confirm = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Row(
            children: [
              Icon(Icons.logout, color: Color(0xFFea5429)),
              SizedBox(width: 12),
              Text(
                'Déconnexion',
                style: TextStyle(
                  color: Color(0xFF233360),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Êtes-vous sûr de vouloir vous déconnecter ?',
                style: TextStyle(fontSize: 15, color: Colors.black87),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.grey[700],
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 10,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: const Text(
                      'Annuler',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 4),
                  ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFea5429),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 10,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      elevation: 2,
                    ),
                    child: const Text(
                      'Déconnecter',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );

    // Si l'utilisateur annule ou ferme le dialog, on ne fait rien
    if (confirm != true) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('should_track', false); // ← AJOUTE ÇA

    // Arrêter le suivi
    stopRealtimeTracking();
    _isTrackingActive = false;

    // Arrêter le service de fond
    final service = FlutterBackgroundService();
    service.invoke('stop');

    await prefs.clear();
    setState(() {
      _isLoggedIn = false;
    });
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => const LoginPage()),
    );
    AppToast.showInfo(
      context,
      title: 'Déconnexion réussie',
      description: 'À bientôt !',
    );
  }
}

// Fonction globale pour envoyer la position (gardée pour compatibilité)
Future<void> envoyerPosition() async {
  print('⚠️ envoyerPosition() est dépréciée - Utilisez le stream à la place');
}
