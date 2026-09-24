import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:linarcel/app_toast.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shimmer/shimmer.dart';
import 'package:background_fetch/background_fetch.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';

// Configuration API - MODIFIEZ ICI UNIQUEMENT
//const String API_BASE_URL = 'https://detection-fraude-python.onrender.com';
const String API_BASE_URL = 'http://192.168.1.66:8080';

// Zéro changement mobile : ce garde ne s'active QUE sur Web (Chrome).
// Sur Android/iOS, isBgServiceSupported == true et tout le code existant tourne à l'identique.
bool get isBgServiceSupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

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
  // Web (Chrome) : flutter_background_service n'est pas supporté -> on saute.
  // Android/iOS : comportement strictement inchangé.
  if (!isBgServiceSupported) {
    debugPrint('ℹ️ Service de fond désactivé sur cette plateforme (web).');
    return;
  }

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
      content: "Vous êtes connecté en qu'un VM...",
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
        'timestamp': DateTime.now().toUtc().toIso8601String(),
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

    // Fallback Web (Chrome) : pas de service de fond -> suivi foreground direct.
    // Android/iOS : on garde le bloc service existant à l'identique.
    if (!isBgServiceSupported) {
      final webPrefs = await SharedPreferences.getInstance();
      await webPrefs.setBool('should_track', true);
      startRealtimeTracking();
    } else {
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
    }

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
      locale: const Locale('fr', 'FR'),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('fr', 'FR')],
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
                    clipBehavior: Clip.antiAlias, 
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
                      padding: const EdgeInsets.all(10.0),
                      child: Image.asset(
                        'assets/logo.png',
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
                          // Bouton Connexion : bouton unique, désactivé avec
                          // texte « Connexion... » pendant le chargement.
                          SizedBox(
                            width: double.infinity,
                            height: 52,
                            child: ElevatedButton(
                              onPressed: _isLoading ? null : _login,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF233360),
                                foregroundColor: Colors.white,
                                disabledBackgroundColor: const Color(
                                  0xFF233360,
                                ).withOpacity(0.6),
                                disabledForegroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                elevation: 2,
                              ),
                              child: Text(
                                _isLoading
                                    ? 'Connexion...'
                                    : 'Se connecter',
                                style: const TextStyle(
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
  bool _vmInfoLoading = true;
  String _currentTime = '';
  Timer? _timer;
  bool _isLoggedIn = true;
  bool _isTrackingActive = false;
  bool _isLocationLoading = false;
  // Heure du point déclarée (chaque jour sauf dimanche, modifiable 15 min).
  String? _heurePoint;
  String? _heurePointDate;
  DateTime? _heurePointExpireAt;
  bool? _heurePointHorsPlage;
  bool _heurePointLoading = false;
  bool _heurePointSaving = false;

  @override
  void initState() {
    super.initState();
    _loadVmInfo();
    _updateTime();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _updateTime();
    });

    // Service de fond : Android/iOS uniquement. Sur Web on saute
    // (le constructeur FlutterBackgroundService() lève sinon).
    if (isBgServiceSupported) {
      FlutterBackgroundService().on('trackingStarted').listen((event) {
        if (mounted) setState(() => _isTrackingActive = true);
      });
    }

    // Démarrer le suivi après un court délai pour que l'UI soit chargée
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startLocationTracking();
      _chargerHeurePoint();
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

  /// Pull-to-refresh : recharge le profil + l'heure du point en parallèle.
  /// L'indicateur natif reste visible jusqu'à la fin des deux chargements.
  Future<void> _rafraichir() async {
    _updateTime();
    await Future.wait([_loadVmInfo(), _chargerHeurePoint()]);
  }

  Future<void> _loadVmInfo() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _vmNumero = prefs.getString('numero') ?? 'Inconnu';
      _vmNom = prefs.getString('nom') ?? 'Vendeur';
      _vmInfoLoading = false;
    });
  }

  // --- Heure du point (déclarée chaque jour sauf dimanche) ---
  bool _isDimanche() => DateTime.now().weekday == DateTime.sunday;
  //bool _isDimanche() => false; 

  String _dateJourStr() {
    final now = DateTime.now();
    return '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}';
  }

  bool get _heurePointModifiable {
    if (_heurePoint == null || _heurePointExpireAt == null) return _heurePoint == null;
    return DateTime.now().isBefore(_heurePointExpireAt!);
  }

  String _resteEditStr() {
    if (_heurePointExpireAt == null) return '';
    final reste = _heurePointExpireAt!.difference(DateTime.now());
    if (reste.isNegative) return 'verrouillée';
    final mm = reste.inMinutes;
    final ss = reste.inSeconds % 60;
    return 'modifiable encore ${mm}min ${ss.toString().padLeft(2, '0')}s';
  }

  Future<void> _chargerHeurePoint() async {
    if (_isDimanche()) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final vmId = prefs.getString('vm_id');
      final token = prefs.getString('token');
      if (vmId == null || token == null) return;
      if (mounted) setState(() => _heurePointLoading = true);
      final dateStr = _dateJourStr();
      final uri = Uri.parse('$API_BASE_URL/api/vm/heure-point').replace(
        queryParameters: {'vm_id': vmId, 'token': token, 'date': dateStr},
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (!mounted) return;
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _heurePointLoading = false;
          if (data['exists'] == true) {
            _heurePoint = data['heure_point']?.toString();
            _heurePointDate = data['date']?.toString();
            final exp = data['modifiable_jusqu_a']?.toString();
            _heurePointExpireAt = exp != null ? DateTime.tryParse(exp)?.toLocal() : null;
          } else {
            _heurePoint = null;
            _heurePointDate = dateStr;
            _heurePointExpireAt = null;
          }
        });
      } else {
        if (mounted) setState(() => _heurePointLoading = false);
      }
    } catch (_) {
      if (mounted) setState(() => _heurePointLoading = false);
    }
  }

  Future<void> _choisirHeurePoint() async {
    if (_isDimanche()) return;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
      helpText: 'Heure de votre point à l\'agence',
      // Français 24h : 15:30 au lieu de 3:30 PM, quel que soit le téléphone.
      builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
      child: Theme(
        data: Theme.of(context).copyWith(
          timePickerTheme: const TimePickerThemeData(
            hourMinuteTextStyle: TextStyle(fontSize: 40, fontWeight: FontWeight.bold),
          ),
        ),
        child: child!,
      ),
),
    );
    if (picked == null || !mounted) return;
    // Refuser les heures futures : on ne déclare que l'heure actuelle ou passée.
    final now = TimeOfDay.now();
    if (picked.hour * 60 + picked.minute > now.hour * 60 + now.minute) {
      final heureActuelle =
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
      AppToast.showError(
        context,
        title: 'Heure invalide',
        description:
            'Il est $heureActuelle : vous ne pouvez pas déclarer une heure future.',
      );
      return;
    }
    await _enregistrerHeurePoint(picked);
  }

  Future<void> _enregistrerHeurePoint(TimeOfDay tod) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final vmId = prefs.getString('vm_id');
      final token = prefs.getString('token');
      if (vmId == null || token == null) {
        AppToast.showError(context, title: 'Session invalide', description: 'Reconnectez-vous.');
        return;
      }
      setState(() => _heurePointSaving = true);
      final heureStr =
          '${tod.hour.toString().padLeft(2, '0')}:${tod.minute.toString().padLeft(2, '0')}';
      final response = await http
          .post(
            Uri.parse('$API_BASE_URL/api/vm/heure-point'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'vm_id': int.parse(vmId),
              'token': token,
              'heure_point': heureStr,
              'date': _dateJourStr(),
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;
      setState(() => _heurePointSaving = false);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _heurePoint = data['heure_point']?.toString() ?? heureStr;
          _heurePointDate = data['date']?.toString() ?? _dateJourStr();
          final exp = data['modifiable_jusqu_a']?.toString();
          _heurePointExpireAt = exp != null ? DateTime.tryParse(exp)?.toLocal() : null;
          _heurePointHorsPlage = data['hors_plage'] == true;
        });
        AppToast.showSuccess(
          context,
          title: 'Heure du point enregistrée',
          description: _heurePointHorsPlage == true
              ? 'Point à $_heurePoint (hors 12h-16h : alerte envoyée à la centrale).'
              : 'Point à $_heurePoint. Modifiable pendant 15 min.',
        );
      } else {
        String message = 'Impossible d\'enregistrer l\'heure.';
        try {
          final err = jsonDecode(response.body);
          if (err is Map && err['detail'] != null) message = err['detail'].toString();
        } catch (_) {}
        AppToast.showError(context, title: 'Erreur', description: message);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _heurePointSaving = false);
        AppToast.showError(context, title: 'Erreur', description: 'Une erreur est survenue. Veuillez réessayer.');
      }
    }
  }

  Future<void> _startLocationTracking() async {
    if (_isTrackingActive) return;
    setState(() => _isLocationLoading = true);

    bool success = await requestLocationPermissionAndStartTracking();

    setState(() {
      _isLocationLoading = false;
      //_isTrackingActive = success;
      // Web uniquement : pas d'évènement 'trackingStarted' (pas de service),
      // donc on reflète le succès du suivi foreground direct.
      // Mobile : inchangé, c'est l'écouteur du service qui met à jour.
      if (!isBgServiceSupported && success) {
        _isTrackingActive = true;
      }
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

  Widget _buildHeurePointCard() {
    return Container(
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
            const Row(
              children: [
                Icon(Icons.access_time, color: Color(0xFF233360), size: 24),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Heure du point',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF233360),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_isDimanche())
              const Text(
                'Pas de point le dimanche. Reprise demain.',
                style: TextStyle(fontSize: 13, color: Colors.grey, height: 1.4),
              )
            else if (_heurePointLoading)
              // Shimmer qui mime les lignes de texte attendues (pas de spinner).
              Shimmer.fromColors(
                baseColor: Colors.grey.shade300,
                highlightColor: Colors.grey.shade100,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      height: 13,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      height: 13,
                      width: 200,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                  ],
                ),
              )
            else if (_heurePoint == null)
              const Text(
                'Après votre point à l\'agence, déclarez ici l\'heure (et minutes) du point du jour.',
                style: TextStyle(fontSize: 13, color: Colors.grey, height: 1.4),
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF233360).withOpacity(0.08),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '$_heurePoint${_heurePointDate != null ? '  •  $_heurePointDate' : ''}',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF233360),
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _heurePointModifiable
                        ? 'Déclaré — ${_resteEditStr()} en cas d\'erreur.'
                        : 'Déclaré — saisie ${_resteEditStr()}.',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  
                ],
              ),
            if (!_isDimanche() && (_heurePoint == null || _heurePointModifiable)) ...[
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton.icon(
                  onPressed: _heurePointSaving ? null : _choisirHeurePoint,
                  icon: _heurePointSaving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.schedule, size: 20),
                  label: Text(
                    _heurePoint == null ? 'Déclarer l\'heure du point' : 'Modifier l\'heure',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFea5429),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    elevation: 2,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: AppBar(
        title: const Text(
          'Espace vendeur motorisé',
          style: TextStyle(
            fontSize: 16,
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
      body: RefreshIndicator(
        onRefresh: _rafraichir,
        color: const Color(0xFFea5429),
        backgroundColor: Colors.white,
        child: SingleChildScrollView(
          // Permet de tirer vers le bas même quand le contenu est court.
          physics: const AlwaysScrollableScrollPhysics(),
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
                        width: 40,
                        height: 40,
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
                              size: 24,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _vmInfoLoading
                            // Shimmer qui mime les lignes nom + numéro (pas de spinner).
                            ? Shimmer.fromColors(
                                baseColor: Colors.white.withOpacity(0.4),
                                highlightColor: Colors.white.withOpacity(0.9),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      height: 16,
                                      width: 140,
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Container(
                                      height: 13,
                                      width: 100,
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _vmNom,
                              style: const TextStyle(
                                fontSize: 16,
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
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF233360),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'Pour garantir la bonne organisation de votre secteur, merci de renseigner rigoureusement vos heures de pointage en agence.',
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
                  // Carte heure du point (déclarée chaque jour sauf dimanche)
                  _buildHeurePointCard(),
                  const SizedBox(height: 16),
                  // Carte changement de mot de passe
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
                          const Row(
                            children: [
                              Icon(
                                Icons.lock_reset,
                                color: Color(0xFF233360),
                                size: 24,
                              ),
                              SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  'Sécurité du compte',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF233360),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Modifiez régulièrement votre mot de passe pour protéger votre compte.',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey,
                              height: 1.4,
                            ),
                          ),
                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            height: 50,
                            child: ElevatedButton.icon(
                              onPressed: _showChangePasswordDialog,
                              icon: const Icon(Icons.lock_outline, size: 20),
                              label: const Text(
                                'Changer mon mot de passe',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF233360),
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                elevation: 2,
                              ),
                            ),
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

  Future<void> _showChangePasswordDialog() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _ChangePasswordDialog(),
    );

    if (ok == true && mounted) {
      AppToast.showSuccess(
        context,
        title: 'Mot de passe modifié',
        description: 'Votre nouveau mot de passe est actif.',
      );
    }
  }

  Future<void> _logout() async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        bool isLoading = false;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              title: Row(
                children: [
                  Icon(
                    Icons.logout,
                    color: const Color(0xFFea5429),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'Déconnexion',
                    style: TextStyle(
                      color: Color(0xFF233360),
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
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
                        onPressed: isLoading
                            ? null
                            : () => Navigator.of(dialogContext).pop(false),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.grey[700],
                          disabledForegroundColor: Colors.grey[400],
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
                        onPressed: isLoading
                            ? null
                            : () async {
                                setDialogState(() => isLoading = true);

                                final prefs = await SharedPreferences.getInstance();
                                final logoutVmId = prefs.getString('vm_id');
                                final logoutToken = prefs.getString('token');
                                if (logoutVmId != null && logoutToken != null) {
                                  try {
                                    await http
                                        .post(
                                          Uri.parse('$API_BASE_URL/api/logout'),
                                          headers: {'Content-Type': 'application/json'},
                                          body: jsonEncode({
                                            'vm_id': int.parse(logoutVmId),
                                            'token': logoutToken,
                                          }),
                                        )
                                        .timeout(const Duration(seconds: 8));
                                  } catch (_) {}
                                }

                                await prefs.setBool('should_track', false);
                                stopRealtimeTracking();
                                _isTrackingActive = false;

                                if (isBgServiceSupported) {
                                  final service = FlutterBackgroundService();
                                  service.invoke('stop');
                                }

                                await prefs.clear();

                                if (dialogContext.mounted) {
                                  Navigator.of(dialogContext).pop(true);
                                }
                              },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFea5429),
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: const Color(0xFFea5429).withOpacity(0.6),
                          disabledForegroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 10,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          elevation: 2,
                        ),
                        child: Text(
                          isLoading ? 'Déconnexion' : 'Déconnecter',
                          maxLines: 1, // Force le texte sur une seule ligne
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    if (confirm != true) return;

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

/// Dialogue de changement de mot de passe (VM).
///
/// Widget dédié (et non `StatefulBuilder` + contrôleurs externes) pour que
/// le framework gère le cycle de vie : les contrôleurs sont créés dans
/// `initState` et disposés dans `dispose()`, donc toujours APRÈS le
/// démontage complet — y compris pendant la transition inverse du pop.
/// Ça corrige le crash `_dependents.isEmpty : is not true` qui survenait
/// quand on fermait le modal avec un champ focalisé (clavier ouvert).
class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog();

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  late final TextEditingController _ancienController;
  late final TextEditingController _nouveauController;
  late final TextEditingController _confirmController;
  bool _obscureAncien = true;
  bool _obscureNouveau = true;
  bool _obscureConfirm = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _ancienController = TextEditingController();
    _nouveauController = TextEditingController();
    _confirmController = TextEditingController();
  }

  @override
  void dispose() {
    // Le framework appelle dispose() après démontage complet : sûr ici.
    _ancienController.dispose();
    _nouveauController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  void _fermer(bool resultat) {
    // Retirer le focus AVANT le pop : le champ focalisé est libéré
    // pendant que le sous-arbre est encore monté.
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(resultat);
  }

  InputDecoration _champDecoration(
    String label,
    IconData icon,
    bool obscure,
    VoidCallback toggle,
  ) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Color(0xFF233360)),
      prefixIcon: Icon(icon, color: const Color(0xFFea5429)),
      suffixIcon: IconButton(
        icon: Icon(
          obscure ? Icons.visibility_off : Icons.visibility,
          color: Colors.grey,
        ),
        onPressed: toggle,
      ),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.grey, width: 1),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFea5429), width: 2),
      ),
    );
  }

  Future<void> _sauvegarder() async {
    final ancien = _ancienController.text.trim();
    final nouveau = _nouveauController.text.trim();
    final confirm = _confirmController.text.trim();

    if (ancien.isEmpty || nouveau.isEmpty || confirm.isEmpty) {
      AppToast.showError(
        context,
        title: 'Champs requis',
        description: 'Veuillez remplir les trois champs.',
      );
      return;
    }
    if (nouveau.length < 4) {
      AppToast.showError(
        context,
        title: 'Mot de passe trop court',
        description: 'Le nouveau mot de passe doit contenir au moins 4 caractères.',
      );
      return;
    }
    if (nouveau != confirm) {
      AppToast.showError(
        context,
        title: 'Confirmation différente',
        description: 'La confirmation ne correspond pas au nouveau mot de passe.',
      );
      return;
    }

    setState(() => _isSaving = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final vmId = prefs.getString('vm_id');
      final token = prefs.getString('token');
      if (vmId == null || token == null) {
        throw Exception('Session invalide. Reconnectez-vous.');
      }
      final response = await http
          .post(
            Uri.parse('$API_BASE_URL/api/vm/change-password'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'vm_id': int.parse(vmId),
              'token': token,
              'ancien_password': ancien,
              'nouveau_password': nouveau,
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (!mounted) return;
      if (response.statusCode == 200) {
        _fermer(true);
      } else {
        String message = 'Impossible de modifier le mot de passe.';
        try {
          final data = jsonDecode(response.body);
          if (data is Map && data['detail'] != null) {
            message = data['detail'].toString();
          }
        } catch (_) {}
        AppToast.showError(context, title: 'Erreur', description: message);
      }
    } catch (e) {
      if (mounted) {
        AppToast.showError(
          context,
          title: 'Erreur',
          description: e.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Row(
        children: [
          Icon(Icons.lock_reset, color: Color(0xFFea5429)),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Changer le mot de passe',
              style: TextStyle(
                color: Color(0xFF233360),
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _ancienController,
              obscureText: _obscureAncien,
              decoration: _champDecoration(
                'Ancien mot de passe',
                Icons.lock,
                _obscureAncien,
                () => setState(() => _obscureAncien = !_obscureAncien),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nouveauController,
              obscureText: _obscureNouveau,
              decoration: _champDecoration(
                'Nouveau mot de passe',
                Icons.lock_outline,
                _obscureNouveau,
                () => setState(() => _obscureNouveau = !_obscureNouveau),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _confirmController,
              obscureText: _obscureConfirm,
              decoration: _champDecoration(
                'Confirmer le nouveau',
                Icons.verified_user,
                _obscureConfirm,
                () => setState(() => _obscureConfirm = !_obscureConfirm),
              ),
              onSubmitted: (_) => _sauvegarder(),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _isSaving ? null : () => _fermer(false),
                  child: const Text(
                    'Annuler',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 4),
                ElevatedButton(
                  onPressed: _isSaving ? null : _sauvegarder,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF233360),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(
                    _isSaving ? 'Modification...' : 'Enregistrer',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// Fonction globale pour envoyer la position (gardée pour compatibilité)
Future<void> envoyerPosition() async {
  print('⚠️ envoyerPosition() est dépréciée - Utilisez le stream à la place');
}
