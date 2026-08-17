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
  await initializeService();

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

    // Mettre à jour la notification
    service.setForegroundNotificationInfo(
      title: "Linarcel - App mobile",
      content: "Vous êtes connecté en tant que Vendeur Motorisé.",
    );
  }

  // NE PAS démarrer le suivi ici - il sera démarré après l'obtention des permissions
  // startRealtimeTracking();

  service.on('stop').listen((event) {
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
              now.difference(_lastSentTime!).inSeconds < 10) {
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
    if (_currentToken == null || _currentVmId == null) {
      print('⚠️ Token ou VM ID manquant');
      return;
    }

    final response = await http.post(
      Uri.parse('$API_BASE_URL/api/localisation'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_currentToken',
      },
      body: jsonEncode({
        'vm_id': int.parse(_currentVmId!),
        'latitude': position.latitude,
        'longitude': position.longitude,
        'precision_meters': position.accuracy,
        'vitesse': position.speed,
        'timestamp': DateTime.now().toIso8601String(),
      }),
    );

    if (response.statusCode == 200) {
      print('✅ Position envoyée avec succès');
    } else {
      print(
        '❌ Erreur envoi position: ${response.statusCode} - ${response.body}',
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
    startRealtimeTracking();

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
      home: const LoginPage(),
      debugShowCheckedModeBanner: false,
    );
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
                              ? const Center(
                                  child: CircularProgressIndicator(
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      Color(0xFFea5429),
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
      _isTrackingActive = success;
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
          'Mon espace',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: Color(0xFF233360),
          ),
        ),
        centerTitle: true,
        backgroundColor: Colors.white,
        elevation: 0,
        actions: [
          // IconButton(
          //   icon: const Icon(Icons.logout, color: Color(0xFFea5429)),
          //   onPressed: _logout,
          // ),
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
                                fontSize: 20,
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
                      if (_isLocationLoading)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              ),
                              SizedBox(width: 8),
                              Text(
                                'Activation...',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        )
                      else if (_isTrackingActive)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.location_on,
                                color: Colors.white,
                                size: 14,
                              ),
                              SizedBox(width: 4),
                              Text(
                                'Suivi actif',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
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
                            'Cette application vous permet de rester connecté à la plateforme Linarcel et de bénéficier de toutes nos fonctionnalités dédiées aux Vendeurs Motorisés.',
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
                  // Carte des fonctionnalités
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
                                    0xFFea5429,
                                  ).withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Icon(
                                  Icons.stars,
                                  color: Color(0xFFea5429),
                                  size: 24,
                                ),
                              ),
                              const SizedBox(width: 16),
                              const Text(
                                'Services disponibles',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF233360),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          _buildFeatureItem(
                            icon: Icons.dashboard,
                            title: 'Tableau de bord',
                            description:
                                'Accédez à vos indicateurs de performance',
                            iconColor: const Color(0xFF233360),
                          ),
                          _buildFeatureItem(
                            icon: Icons.notifications_active,
                            title: 'Alertes en temps réel',
                            description:
                                'Soyez informé des activités suspectes',
                            iconColor: const Color(0xFFea5429),
                          ),
                          _buildFeatureItem(
                            icon: Icons.support_agent,
                            title: 'Support Linarcel',
                            description: 'Assistance disponible 24h/24',
                            iconColor: const Color(0xFF233360),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 80),
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
              _isTrackingActive ? 'Suivi actif' : 'Suivi inactif',
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

  Widget _buildFeatureItem({
    required IconData icon,
    required String title,
    required String description,
    required Color iconColor,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: iconColor),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _logout() async {
    // Arrêter le suivi
    stopRealtimeTracking();
    _isTrackingActive = false;

    // Arrêter le service de fond
    final service = FlutterBackgroundService();
    service.invoke('stop');

    final prefs = await SharedPreferences.getInstance();
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
