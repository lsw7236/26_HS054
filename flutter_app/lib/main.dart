import 'dart:convert';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_device_compass/flutter_device_compass.dart';
import 'package:http/http.dart' as http;
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'services/tts_service.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SmartCane',
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'Roboto',
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF155EEF),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF6F7F9),
      ),
      home: const VoiceCommandPage(),
    );
  }
}

class VoiceCommandPage extends StatefulWidget {
  const VoiceCommandPage({super.key});

  @override
  State<VoiceCommandPage> createState() => _VoiceCommandPageState();
}

class _VoiceCommandPageState extends State<VoiceCommandPage> with WidgetsBindingObserver {
  // Android 하드웨어 버튼과 Flutter 사이의 통신 채널
  static const MethodChannel _hardwareKeyChannel =
      MethodChannel('smartcane/hardware_key');

  // 최신 3탭 UI: 0 홈, 1 길안내, 2 설정
  int _selectedTabIndex = 0;

  // 같은 길안내 방향이 계속 유지될 때 음성과 진동을 다시 안내하는 간격
  static const Duration _navigationRepeatInterval = Duration(seconds: 10);
  static const Duration _directionChangeCooldown = Duration(seconds: 6);

  static const String _openAiApiKey =
      String.fromEnvironment('OPENAI_API_KEY');

  // 의도 분석 모델. 분류/추출용 경량 모델이며 reasoning effort "none"을 지원한다.
  static const String _openAiModel = 'gpt-6-luna';

  static const String _kakaoRestApiKey =
      String.fromEnvironment('KAKAO_REST_API_KEY');

  static const String _kakaoJavaScriptKey =
      String.fromEnvironment('KAKAO_JAVASCRIPT_KEY');
  
  static const String _bleServiceUuid =
      '12345678-1234-5678-1234-56789abcdef0';

  static const String _bleCharacteristicUuid =
      '12345678-1234-5678-1234-56789abcdef1';
// 위 uid는 테스트용 이후 삭제하기
/*
  static const String _bleServiceUuid 
      '03b80e5a-ede8-4b33-a751-6ce34ec4c700';

  static const String _bleCharacteristicUuid =
      '7772e5db-3868-4112-a1a9-f2669d106bf3';
*/


  final stt.SpeechToText _speech = stt.SpeechToText();
  final TtsService _ttsService = TtsService();

  DateTime? _lastObjectAnnouncementAt;
  String _lastObjectAnnouncementKey = '';

  bool _speechAvailable = false;
  bool _isListening = false;
  bool _isAnalyzing = false;

  bool _isFindingRoute = false;
  bool _autoAnalyzeStarted = false;

  // BLE 쓰기를 직렬화한다.
  // FIND 전송 중 STOP이 들어오더라도 STOP을 버리지 않고 앞선 쓰기 다음에 전송한다.
  Future<void> _bleWriteQueue = Future<void>.value();

  // 비동기 GPT 의도 분석/길찾기 작업을 무효화하기 위한 세대 번호.
  // 초기화나 새 명령이 시작되면 증가시켜 이전 작업의 늦은 결과를 무시한다.
  int _commandEpoch = 0;

  // 위험 TTS 반복 및 우선순위 제어
  // - 어떤 위험이든 최소 2.5초 간격
  // - 같은 위험은 최소 5초 간격
  // - 위험 안내 직후 2초 동안 낮은 우선순위 TTS 보류
  static const Duration _hazardGlobalTtsInterval =
      Duration(milliseconds: 2500);
  static const Duration _hazardSameTtsInterval =
      Duration(seconds: 5);
  static const Duration _hazardPriorityHold =
      Duration(seconds: 2);

  DateTime? _lastHazardAnnouncementAt;
  String _lastHazardAnnouncementKey = '';

  // 길안내 시작·잠시 멈춤·재개·취소·도착처럼 꼭 들어야 하는 안내는
  // 턴 안내와 별도 칸에 보류해, 위험 해제 뒤 턴 안내보다 먼저 읽는다.
  String _pendingImportantTts = '';
  // 위험이 짧게 반복될 때 해제 콜백이 겹쳐 두 번 읽지 않도록 가장 최근 해제만 유효하게 한다.
  int _hazardClearToken = 0;

  // Native Bluetooth LE state (Android)
  BluetoothDevice? _bleDevice;
  BluetoothCharacteristic? _bleCharacteristic;
  StreamSubscription<List<int>>? _bleNotifySubscription;
  StreamSubscription<BluetoothConnectionState>? _bleConnectionSubscription;
  StreamSubscription<Position>? _navigationPositionSubscription;
  StreamSubscription<CompassEvent>? _compassSubscription;

  bool _hazardDisplayActive = false;

  // 위험 감지 안내 설정 (설정 탭에서 조절, 앱을 다시 켜도 유지)
  // - _hazardAlertEnabled: false면 지팡이가 보낸 위험 패킷을 화면/음성에 쓰지 않는다.
  // - _hazardAlertDistanceCm: 방향(정면/양쪽/위쪽)별로 이 거리(cm) 이내의 장애물만 위험으로 안내한다.
  //   기본값(= 최대값)이면 지팡이의 기본 판정(정면 150cm, 양쪽 75cm, 위쪽 200cm)을 그대로 쓴다.
  // 값들은 BLE HAZARD:ON/OFF, HAZARD:DIST:<FRONT|SIDE|UPPER>:<cm> 명령으로 지팡이에도 전달되어
  // Raspberry Pi의 위험 판정과 진동 경고 자체를 켜고 끄거나 방향별 거리를 좁힌다.
  static const String _prefHazardAlertEnabled = 'hazard_alert_enabled';
  // 예전 단일 거리 설정. 방향별 값이 아직 없을 때 한 번 옮겨 쓰는 데만 읽는다.
  static const String _prefHazardAlertDistanceCm = 'hazard_alert_distance_cm';
  static const String _prefHazardAlertDistancePrefix = 'hazard_alert_distance_cm_';
  static const double _hazardAlertDistanceMinCm = 10;
  // 키는 지팡이 HAZARD:DIST:<키>:<cm> 명령과 같다. 값은 지팡이 기본 기준(앱에서 줄일 수 있는 최대값).
  static const Map<String, double> _hazardDirectionDefaultCm = <String, double>{
    'FRONT': 150,
    'SIDE': 75,
    'UPPER': 200,
  };
  static const Map<String, String> _hazardDirectionLabels = <String, String>{
    'FRONT': '정면',
    'SIDE': '양쪽',
    'UPPER': '위쪽',
  };
  bool _hazardAlertEnabled = true;
  final Map<String, double> _hazardAlertDistanceCm =
      Map<String, double>.of(_hazardDirectionDefaultCm);
  // 지팡이가 HAZARD 명령을 받아 적용한 뒤 돌려준 상태 문구. 연결 전/해제 시 비움.
  String _piHazardSettingStatus = '';

  // 저장된 장소 (집, 회사 등). SharedPreferences에 JSON 목록으로 보관.
  // "집으로 안내해줘"처럼 말하면 카카오 장소 검색 없이 저장 좌표로 바로 길안내한다.
  static const String _prefSavedPlaces = 'saved_places_v1';
  List<SavedPlace> _savedPlaces = <SavedPlace>[];
  bool _isSavingPlace = false;

  // ---- 시각장애인 사용 편의 기능 ----
  static const String _prefAutoConnect = 'auto_connect_enabled';
  static const String _prefSimpleMode = 'simple_mode_enabled';
  bool _autoConnectEnabled = true; // 앱 시작 시 지팡이 자동 연결 + 끊기면 자동 재연결
  bool _simpleModeEnabled = false; // 심사용 카드를 숨기고 핵심 UI만 표시
  bool _userDisconnected = false; // 사용자가 직접 연결 해제 → 자동 재연결하지 않음
  bool _isAutoReconnecting = false;
  int _reconnectAttempt = 0;
  static const int _maxReconnectAttempts = 5;
  bool _startupAnnounced = false;
  int _voiceRetryCount = 0; // 되묻기 뒤 자동 재청취는 1회만
  bool _emptyRecognitionHandled = false;
  String _lastAnnouncementText = ''; // "다시 말해줘"용 마지막 안내 문장
  SavedPlace? _pendingDeletePlace; // 음성 삭제 되묻기 중인 장소
  DateTime? _pendingDeleteAskedAt;
  static const Duration _pendingDeleteTimeout = Duration(seconds: 60);
  int _lastSpokenBatteryBucket = -1;
  String _lastSpokenBatteryWarning = '';
  Timer? _wakelockTimer;
  bool _wakelockEnabled = false;

  // 큰 글씨 옵션 (글자 1.3배)
  static const String _prefLargeText = 'large_text_enabled';
  bool _largeTextEnabled = false;

  // 동작 기록 (홈 하단 카드, 심사용). tof/status 같은 주기 패킷은 제외.
  static const int _bleLogMaxEntries = 40;
  final List<BleLogEntry> _bleLog = <BleLogEntry>[];
  bool _bleLogShowRaw = false;
  String _bleLogFilter = ''; // '' = 전체
  String _lastObjectDisplayTitle = '';
  String _lastObjectDisplaySubtitle = '';

  // Raspberry Pi / X120x status received via BLE
  double? _piBattery;
  String _piCharging = '-';
  String _piWarning = '';
  DateTime? _piStatusUpdatedAt;

  bool _isBleScanning = false;
  bool _isBleConnected = false;

  // Raspberry Pi가 실제로 로드한 YOLO 모델의 클래스 목록을 BLE로 받는다.
  // 앱에는 80개 클래스나 한국어 별칭을 하드코딩하지 않는다.
  List<String> _yoloClasses = <String>[];
  final Map<int, List<String>> _yoloClassChunks = <int, List<String>>{};
  int _expectedYoloClassChunks = 0;
  String _yoloClassBatch = '';
  String _activeObjectTarget = '';
  String _activeObjectLabel = '';
  // 객체 탐색 시 Raspberry Pi가 알려준 방향을 4방향 진동모터 위치로 시각화한다.
  String _activeObjectMotorDirection = '';
  Timer? _objectMotorVisualTimer;

  String _bleStatus = 'SmartCane 연결 안 됨';
  String _bleDeviceName = '';
  String _bleDeviceId = '';

  String _recognizedText = '';
  String _statusTitle = '음성 인식 준비 완료';
  String _statusSubtitle = '마이크에 대고 말씀해주세요.';

  String _routeDestinationName = '-';
  String _routeSummary = '-';
  String _routeFirstGuide = '-';
  String _navigationGuide = '경로를 검색하면 음성 안내가 시작됩니다.';
  String _upcomingNavigationGuide = '';
  String _navigationMotorStatus = '진동 안내 대기';
  // 길안내 화면에서 현재 실제로 울리는 4방향 진동모터를 시각화한다.
  // FORWARD=위, LEFT=왼쪽, RIGHT=오른쪽, UTURN=아래, STOP/빈값=정지
  String _activeNavigationMotorAction = '';
  Timer? _navigationMotorVisualTimer;
  String _navigationDistanceText = '-';
  int _routeTotalDistance = 0;
  int _routeTotalTime = 0;
  bool _isNavigating = false;
  // 길안내 중 물건 찾기 명령이 오면 경로는 유지한 채 안내만 잠시 멈춘다.
  // 물건 찾기가 끝나면(그만) 같은 경로·같은 단계에서 길안내를 이어간다.
  bool _isNavigationPaused = false;
  bool _isRerouting = false;

  // 상태 확인·현재 위치처럼 한 번 읽고 끝나는 안내를 읽는 동안에는
  // 물건 방향 음성이 끼어들어 끊지 않도록 보류해 두었다가 끝나면 읽는다.
  bool _isInfoAnnouncementActive = false;
  Map<String, dynamic>? _pendingObjectAnnouncement;
  DateTime? _pendingObjectAnnouncementAt;
  // 위험 해제 뒤 다시 읽을 물건 방향은 이보다 오래된 것이면 버린다. (물건을 이미 놓쳤을 수 있음)
  static const Duration _pendingObjectAnnouncementMaxAge = Duration(seconds: 6);
  int _currentNavigationStepIndex = 0;
  int _lastDistanceAnnouncementBucket = -1;
  int _offRouteConsecutiveCount = 0;
  DateTime? _lastRerouteAt;

  // 역방향 판정은 휴대폰이 바라보는 방향이 아니라
  // 실제 GPS 이동 벡터를 기준으로 한다.
  Position? _previousRouteProgressPosition;
  int _reverseDirectionConsecutiveCount = 0;
  DateTime? _lastReverseDirectionAnnouncementAt;

  Position? _previousNavigationPosition;
  Position? _latestNavigationPosition;
  double? _currentTravelHeading;
  double? _deviceHeading;
  DateTime? _lastDeviceHeadingAt;
  DateTime? _lastMapHeadingUpdateAt;
  DateTime? _lastCompassGuidanceAt;
  double? _lastMapHeading;
  String _lastDirectionAnnouncementKey = '';
  DateTime? _lastDirectionAnnouncementAt;
  bool _arrivalApproachAnnounced = false;
  bool _arrivalDirectionAnnounced = false;
  String _lastNavigationBleCommand = '';
  DateTime? _lastNavigationBleCommandAt;
  String _pendingNavigationBleCommand = '';
  int _pendingNavigationBleCount = 0;
  bool _isSendingNavigationToPi = false;
  double? _routeDestinationLongitude;
  double? _routeDestinationLatitude;
  List<KakaoNavigationStep> _navigationSteps = [];

  late final WebViewController _kakaoMapController;
  bool _kakaoMapReady = false;
  String _kakaoMapError = '';
  List<List<double>> _routePoints = [];

  IntentAnalysisResult _analysisResult = IntentAnalysisResult.empty();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeKakaoMap();
    _startCompassTracking();
    _initSpeech();
    _initHardwareKeyControl();
    unawaited(_ttsService.init());
    unawaited(_loadHazardAlertSettings());
    unawaited(_loadSavedPlaces());
    unawaited(_loadAppOptions().then((_) => _runStartupSequence()));
    // 길안내·물건 찾기 중에는 화면이 꺼지지 않게 2초마다 상태를 확인한다.
    _wakelockTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _updateWakelock(),
    );
  }

  void _initHardwareKeyControl() {
    _hardwareKeyChannel.setMethodCallHandler((MethodCall call) async {
      if (!mounted) return;

      if (call.method == 'volumeUpLongPressed') {
        print('[HARDWARE KEY] Volume Up long press');

        if (_isAnalyzing || _isFindingRoute) {
          _showMessage('현재 작업이 끝난 후 다시 시도해주세요.');
          return;
        }

        await _handleVoiceButton();
        return;
      }

      if (call.method == 'volumeDownLongPressed') {
        print('[HARDWARE KEY] Volume Down long press');
        await _handleHardwareCancel();
      }
    });
  }

  void _initializeKakaoMap() {
    _kakaoMapController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..addJavaScriptChannel(
        'MapBridge',
        onMessageReceived: (JavaScriptMessage message) {
          if (!mounted) return;

          if (message.message == 'ready') {
            setState(() {
              _kakaoMapReady = true;
              _kakaoMapError = '';
            });
            unawaited(_drawRouteOnKakaoMap());
          } else {
            setState(() {
              _kakaoMapError = message.message;
            });
          }
        },
      );

    if (_kakaoJavaScriptKey.trim().isEmpty) {
      _kakaoMapError =
          'secrets.json에 KAKAO_JAVASCRIPT_KEY를 입력해주세요.';
      return;
    }

    final String html = '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport"
        content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <style>
    html, body, #map {
      width: 100%;
      height: 100%;
      margin: 0;
      padding: 0;
      overflow: hidden;
    }

    .navigation-position {
      width: 42px;
      height: 42px;
      border-radius: 50%;
      background: rgba(37, 99, 235, 0.18);
      border: 3px solid #ffffff;
      box-shadow: 0 2px 8px rgba(0, 0, 0, 0.35);
      display: flex;
      align-items: center;
      justify-content: center;
    }

    .navigation-arrow {
      width: 0;
      height: 0;
      border-left: 10px solid transparent;
      border-right: 10px solid transparent;
      border-bottom: 25px solid #2563EB;
      filter: drop-shadow(0 1px 1px rgba(0, 0, 0, 0.35));
      transform-origin: 50% 58%;
      transition: transform 160ms linear;
    }
  </style>
  <script
    src="https://dapi.kakao.com/v2/maps/sdk.js?appkey=$_kakaoJavaScriptKey&autoload=false">
  </script>
</head>
<body>
  <div id="map"></div>
  <script>
    var map = null;
    var routeLine = null;
    var startMarker = null;
    var endMarker = null;
    var currentPositionOverlay = null;
    var currentArrowElement = null;
    var followCurrentLocation = false;
    var lastCurrentPosition = null;
    var currentRouteBounds = null;

    window.onerror = function(message) {
      MapBridge.postMessage('카카오 지도 오류: ' + message);
    };

    kakao.maps.load(function() {
      var container = document.getElementById('map');
      var options = {
        center: new kakao.maps.LatLng(37.5665, 126.9780),
        level: 5
      };

      map = new kakao.maps.Map(container, options);

      // 사용자가 지도를 직접 움직이거나 확대/축소하면
      // 현재 위치 자동 추적을 일시 해제한다.
      kakao.maps.event.addListener(map, 'dragstart', function() {
        followCurrentLocation = false;
      });

      kakao.maps.event.addListener(map, 'zoom_changed', function() {
        followCurrentLocation = false;
      });

      MapBridge.postMessage('ready');
    });

    function showRoute(points) {
      if (map == null || points == null || points.length < 2) {
        MapBridge.postMessage('경로 좌표가 부족합니다.');
        return;
      }

      clearRoute();

      // WebView가 실제 화면 크기로 배치된 뒤 지도 크기를 다시 계산한다.
      map.relayout();

      var path = [];
      var bounds = new kakao.maps.LatLngBounds();

      for (var i = 0; i < points.length; i++) {
        var longitude = Number(points[i][0]);
        var latitude = Number(points[i][1]);

        if (!Number.isFinite(longitude) ||
            !Number.isFinite(latitude)) {
          continue;
        }

        // 대한민국 범위를 크게 벗어나는 잘못된 좌표를 제외한다.
        if (longitude < 124 || longitude > 132 ||
            latitude < 32 || latitude > 40) {
          continue;
        }

        var position = new kakao.maps.LatLng(latitude, longitude);

        path.push(position);
        bounds.extend(position);
      }

      if (path.length < 2) {
        MapBridge.postMessage('사용할 수 있는 경로 좌표가 부족합니다.');
        return;
      }

      routeLine = new kakao.maps.Polyline({
        map: map,
        path: path,
        strokeWeight: 8,
        strokeColor: '#2563EB',
        strokeOpacity: 1.0,
        strokeStyle: 'solid'
      });

      endMarker = new kakao.maps.Marker({
        map: map,
        position: path[path.length - 1],
        title: '목적지'
      });

      currentRouteBounds = bounds;
      followCurrentLocation = false;

      // 경로를 처음 그릴 때는 출발지~목적지를 한눈에 보여준다.
      setTimeout(function() {
        showEntireRoute();
      }, 200);
    }

    function clearRoute() {
      if (routeLine != null) {
        routeLine.setMap(null);
        routeLine = null;
      }

      if (startMarker != null) {
        startMarker.setMap(null);
        startMarker = null;
      }

      if (endMarker != null) {
        endMarker.setMap(null);
        endMarker = null;
      }

      currentRouteBounds = null;

      if (currentPositionOverlay != null) {
        currentPositionOverlay.setMap(null);
        currentPositionOverlay = null;
        currentArrowElement = null;
      }
    }

    function updateCurrentPosition(longitude, latitude, heading) {
      if (map == null) return;

      var position = new kakao.maps.LatLng(latitude, longitude);
      lastCurrentPosition = position;

      if (currentPositionOverlay == null) {
        var positionElement = document.createElement('div');
        positionElement.className = 'navigation-position';

        currentArrowElement = document.createElement('div');
        currentArrowElement.className = 'navigation-arrow';
        positionElement.appendChild(currentArrowElement);

        currentPositionOverlay = new kakao.maps.CustomOverlay({
          map: map,
          position: position,
          content: positionElement,
          xAnchor: 0.5,
          yAnchor: 0.5,
          zIndex: 10
        });
      } else {
        currentPositionOverlay.setPosition(position);
      }

      updateCurrentHeading(heading);

      // 자동 추적 상태에서만 현재 위치를 중앙에 유지한다.
      // 사용자가 지도를 직접 움직인 경우에는 다시 끌어오지 않는다.
      if (followCurrentLocation) {
        map.setCenter(position);
      }
    }

    function moveToCurrentLocation() {
      if (map == null || lastCurrentPosition == null) return;

      followCurrentLocation = true;
      map.relayout();
      map.setLevel(3);
      map.setCenter(lastCurrentPosition);
    }

    function showEntireRoute() {
      if (map == null || currentRouteBounds == null) return;

      followCurrentLocation = false;
      map.relayout();
      map.setBounds(currentRouteBounds, 50, 50, 50, 50);
    }

    function updateCurrentHeading(heading) {
      if (heading === null || heading === undefined) return;
      var numericHeading = Number(heading);
      if (currentArrowElement != null && Number.isFinite(numericHeading)) {
        currentArrowElement.style.transform =
            'rotate(' + numericHeading + 'deg)';
      }
    }
  </script>
</body>
</html>
''';

    unawaited(
      _kakaoMapController.loadHtmlString(
        html,
        baseUrl: 'file://',
      ),
    );
  }

  Future<void> _moveKakaoMapToCurrentLocation() async {
    if (!_kakaoMapReady) return;

    try {
      await _kakaoMapController.runJavaScript('moveToCurrentLocation();');
    } catch (error) {
      print('카카오맵 현 위치 이동 오류: $error');
    }
  }

  Future<void> _showEntireKakaoRoute() async {
    if (!_kakaoMapReady || _routePoints.length < 2) return;

    try {
      await _kakaoMapController.runJavaScript('showEntireRoute();');
    } catch (error) {
      print('카카오맵 전체 경로 보기 오류: $error');
    }
  }

  Future<void> _drawRouteOnKakaoMap() async {
    if (!_kakaoMapReady || _routePoints.length < 2) return;

    // WebViewWidget이 실제 화면 크기로 배치될 때까지 기다린다.
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final String pointsJson = jsonEncode(_routePoints);
    await _kakaoMapController.runJavaScript('showRoute($pointsJson);');
  }

  Future<void> _clearRouteOnKakaoMap() async {
    _routePoints = [];

    if (_kakaoMapReady) {
      await _kakaoMapController.runJavaScript('clearRoute();');
    }
  }


  Future<void> _stopAllAudioOutput({bool stopSpeechRecognition = true}) async {
    _pendingImportantTts = '';

    if (stopSpeechRecognition) {
      try {
        await _speech.cancel();
      } catch (_) {
        try {
          await _speech.stop();
        } catch (_) {}
      }
    }

    try {
      await _ttsService.stop();
    } catch (error) {
      print('음성 출력 중지 오류: $error');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      final bool keepGuiding = _isNavigating ||
          _isFindingRoute ||
          _activeObjectTarget.trim().isNotEmpty;

      if (keepGuiding && state != AppLifecycleState.detached) {
        // 길안내·물건 찾기 중에는 앱이 가려지거나 화면이 꺼져도 음성 안내를 유지한다.
        // 마이크 입력만 정리한다.
        if (_isListening) {
          unawaited(_speech.cancel());
          if (mounted) {
            setState(() {
              _isListening = false;
            });
          }
        }
        print('[LIFECYCLE] $state · 안내 중이므로 음성 출력 유지');
        return;
      }

      unawaited(_stopAllAudioOutput());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _navigationMotorVisualTimer?.cancel();
    _objectMotorVisualTimer?.cancel();
    _wakelockTimer?.cancel();
    unawaited(WakelockPlus.disable());
    _hardwareKeyChannel.setMethodCallHandler(null);
    unawaited(_bleNotifySubscription?.cancel() ?? Future<void>.value());
    unawaited(_bleConnectionSubscription?.cancel() ?? Future<void>.value());
    unawaited(
      _navigationPositionSubscription?.cancel() ?? Future<void>.value(),
    );
    unawaited(_compassSubscription?.cancel() ?? Future<void>.value());
    unawaited(_stopAllAudioOutput());
    super.dispose();
  }

  void _startCompassTracking() {
    final Stream<CompassEvent>? events = FlutterCompass.events;
    if (events == null) return;

    _compassSubscription = events.listen(
      _handleCompassEvent,
      onError: (Object error) {
        print('휴대폰 방향 센서 오류: $error');
      },
    );
  }

  void _handleCompassEvent(CompassEvent event) {
    final double? rawHeading = event.heading;
    if (rawHeading == null || !rawHeading.isFinite) return;

    final double normalizedHeading = (rawHeading + 360) % 360;
    final double? previousHeading = _deviceHeading;
    if (previousHeading == null) {
      _deviceHeading = normalizedHeading;
    } else {
      // 0도와 360도 경계를 넘을 때도 자연스럽게 움직이도록 원형 보간한다.
      final double difference =
          (normalizedHeading - previousHeading + 540) % 360 - 180;
      _deviceHeading = (previousHeading + difference * 0.22 + 360) % 360;
    }

    _lastDeviceHeadingAt = DateTime.now();
    _currentTravelHeading = _deviceHeading;

    final Position? position = _latestNavigationPosition;
    if (_isNavigationGuidanceActive && position != null) {
      _updateKakaoMapCurrentPosition(position, throttleHeadingOnly: true);

      final DateTime now = DateTime.now();
      if (_lastCompassGuidanceAt == null ||
          now.difference(_lastCompassGuidanceAt!) >=
              const Duration(milliseconds: 500)) {
        _lastCompassGuidanceAt = now;
        _updateDirectionFromCompass(position);
      }
    }
  }

  void _updateDirectionFromCompass(Position position) {
    if (!mounted ||
        !_isNavigationGuidanceActive ||
        position.accuracy > 35 ||
        _currentTravelHeading == null ||
        _navigationSteps.isEmpty ||
        _currentNavigationStepIndex >= _navigationSteps.length) {
      return;
    }

    final KakaoNavigationStep step =
        _navigationSteps[_currentNavigationStepIndex];
    final double distance = Geolocator.distanceBetween(
      position.latitude,
      position.longitude,
      step.latitude,
      step.longitude,
    );
    final double targetBearing = _targetBearingForStep(position, step);
    final String instruction = _relativeDirectionInstruction(
      _currentTravelHeading!,
      targetBearing,
    );
    final String fullGuide = _currentGuideForStep(
      _currentNavigationStepIndex,
      instruction,
      distance.round(),
    );

    setState(() {
      _navigationGuide = fullGuide;
    });

    unawaited(
      _sendNavigationMotorCommand(
        _relativeNavigationMotorAction(
          _currentTravelHeading!,
          targetBearing,
        ),
      ),
    );

    final DateTime now = DateTime.now();
    final bool changed = instruction != _lastDirectionAnnouncementKey;
    final Duration elapsed = _lastDirectionAnnouncementAt == null
        ? _navigationRepeatInterval
        : now.difference(_lastDirectionAnnouncementAt!);
    final bool directionChangeReady =
        changed && elapsed >= _directionChangeCooldown;
    final bool sameDirectionRepeatReady =
        !changed && elapsed >= _navigationRepeatInterval;

    if ((directionChangeReady || sameDirectionRepeatReady) && distance > 12) {
      _lastDirectionAnnouncementKey = instruction;
      _lastDirectionAnnouncementAt = now;
      unawaited(_speakLowerPriorityAnnouncement(fullGuide));
    }
  }

  void _updateKakaoMapCurrentPosition(
    Position position, {
    bool throttleHeadingOnly = false,
  }) {
    if (!_kakaoMapReady) return;

    final double? heading = _currentTravelHeading;
    if (throttleHeadingOnly && heading != null) {
      final DateTime now = DateTime.now();
      final double? lastHeading = _lastMapHeading;
      final double headingDifference = lastHeading == null
          ? 360
          : ((heading - lastHeading + 540) % 360 - 180).abs();
      if (_lastMapHeadingUpdateAt != null &&
          now.difference(_lastMapHeadingUpdateAt!) <
              const Duration(milliseconds: 180) &&
          headingDifference < 3) {
        return;
      }
      _lastMapHeadingUpdateAt = now;
      _lastMapHeading = heading;

      unawaited(
        _kakaoMapController.runJavaScript(
          'updateCurrentHeading(${heading.toStringAsFixed(1)});',
        ),
      );
      return;
    }

    final String headingValue =
        heading?.toStringAsFixed(1) ?? 'null';
    unawaited(
      _kakaoMapController.runJavaScript(
        'updateCurrentPosition(${position.longitude}, '
        '${position.latitude}, $headingValue);',
      ),
    );
  }

  Future<void> _initSpeech() async {
    final bool available = await _speech.initialize(
      onStatus: (String status) {
        print('Speech status: $status');

        if (!mounted) return;

        if (status == 'done' || status == 'notListening') {
          final bool shouldAutoAnalyze =
              _isListening &&
              !_autoAnalyzeStarted &&
              _recognizedText.trim().isNotEmpty;
          final bool heardNothing =
              _isListening && _recognizedText.trim().isEmpty;

          setState(() {
            _isListening = false;
            _statusTitle = '음성 인식 완료';
            _statusSubtitle = '인식된 내용을 분석하고 있습니다.';
          });

          if (shouldAutoAnalyze) {
            _autoAnalyzeStarted = true;

            Future.delayed(const Duration(milliseconds: 400), () {
              if (mounted) {
                _analyzeIntent();
              }
            });
          } else if (heardNothing) {
            unawaited(_handleEmptyRecognition());
          }
        }
      },
      onError: (error) {
        print('Speech error: ${error.errorMsg}');

        if (!mounted) return;

        setState(() {
          _isListening = false;
          _statusTitle = '음성 인식 오류';
          _statusSubtitle = error.errorMsg;
        });

        _showMessage('음성 인식 오류가 발생했습니다.');

        final String message = error.errorMsg.toString().toLowerCase();
        if (message.contains('no_match') ||
            message.contains('no match') ||
            message.contains('timeout')) {
          // 아무 말도 듣지 못한 경우: 되묻고 한 번 더 듣는다.
          unawaited(_handleEmptyRecognition());
        } else {
          unawaited(
            _ttsService.speak('음성 인식에 문제가 생겼습니다. 잠시 후 다시 시도해 주세요.'),
          );
        }
      },
    );

    if (!mounted) return;

    setState(() {
      _speechAvailable = available;
      _statusTitle = available ? '음성 인식 준비 완료' : '음성 인식 사용 불가';
      _statusSubtitle = available
          ? '마이크 버튼을 눌러 말해보세요.'
          : '현재 기기에서 음성 인식을 사용할 수 없습니다. Chrome 또는 Android에서 테스트하세요.';
    });
  }

  Future<void> _scanSmartCane() async {
    if (_isBleScanning) return;

    StreamSubscription<List<ScanResult>>? scanSubscription;

    try {
      setState(() {
        _isBleScanning = true;
        _isBleConnected = false;
        _bleDevice = null;
        _bleCharacteristic = null;
        _bleDeviceName = '';
        _bleDeviceId = '';
        _bleStatus = 'SmartCane 검색 중...';
      });

      await FlutterBluePlus.stopScan();

      final Completer<BluetoothDevice> foundDevice =
          Completer<BluetoothDevice>();

      scanSubscription = FlutterBluePlus.scanResults.listen(
        (List<ScanResult> results) {
          for (final ScanResult result in results) {
            final String name = result.device.platformName.trim();

            if (name == 'SmartCane' && !foundDevice.isCompleted) {
              foundDevice.complete(result.device);
              break;
            }
          }
        },
      );

      await FlutterBluePlus.startScan(
        withNames: const ['SmartCane'],
        timeout: const Duration(seconds: 8),
      );

      final BluetoothDevice device = await foundDevice.future.timeout(
        const Duration(seconds: 9),
        onTimeout: () {
          throw TimeoutException(
            'SmartCane을 찾지 못했습니다. '
            '라즈베리파이 BLE가 실행 중인지 확인해주세요.',
          );
        },
      );

      await FlutterBluePlus.stopScan();
      await scanSubscription.cancel();

      if (!mounted) return;

      setState(() {
        _bleDevice = device;
        _bleDeviceName = device.platformName.isEmpty
            ? 'SmartCane'
            : device.platformName;
        _bleDeviceId = device.remoteId.toString();
        _isBleScanning = false;
        _bleStatus = 'SmartCane 발견';
      });

      print(
        'BLE device found: '
        '$_bleDeviceName / $_bleDeviceId',
      );

      _showMessage('SmartCane을 찾았습니다.');
    } catch (e) {
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}

      if (scanSubscription != null) {
        try {
          await scanSubscription.cancel();
        } catch (_) {}
      }

      if (!mounted) return;

      setState(() {
        _isBleScanning = false;
        _bleStatus = 'SmartCane 검색 실패';
      });

      print('BLE scan error: $e');
      _showMessage('SmartCane 검색 실패: $e');
    }
  }

  /// [speakConnected]가 false면 "지팡이가 연결되었습니다"를 여기서 말하지 않는다.
  /// (앱 시작 안내처럼 호출한 쪽이 이어서 한 문장으로 말할 때)
  Future<void> _connectSmartCane({bool speakConnected = true}) async {
    final BluetoothDevice? device = _bleDevice;

    if (device == null) {
      _showMessage('먼저 SmartCane 검색 버튼을 눌러주세요.');
      return;
    }

    try {
      setState(() {
        _bleStatus = 'SmartCane 연결 중...';
      });

      await _bleNotifySubscription?.cancel();
      await _bleConnectionSubscription?.cancel();

      _bleConnectionSubscription =
          device.connectionState.listen((BluetoothConnectionState state) {
        if (!mounted) return;

        if (state == BluetoothConnectionState.disconnected &&
            _isBleConnected) {
          print('[BLE] disconnected (userDisconnected=$_userDisconnected)');
          _recordAppLog(
            'connection',
            _userDisconnected ? '지팡이 연결 해제 (사용자)' : '지팡이 연결 끊김',
          );
          unawaited(_stopAllAudioOutput(stopSpeechRecognition: false));
          unawaited(_stopNavigation(resetGuide: true));

          setState(() {
            _isBleConnected = false;
            _bleCharacteristic = null;
            _bleStatus = 'SmartCane 연결 끊김';
            _piHazardSettingStatus = '';
            _yoloClasses = <String>[];
            _yoloClassChunks.clear();
            _expectedYoloClassChunks = 0;
            _yoloClassBatch = '';
            _activeObjectTarget = '';
            _activeObjectLabel = '';
            _hazardDisplayActive = false;
            _lastObjectDisplayTitle = '';
            _lastObjectDisplaySubtitle = '';
            _lastNavigationBleCommand = '';
            _lastNavigationBleCommandAt = null;
            _pendingNavigationBleCommand = '';
            _pendingNavigationBleCount = 0;
            _navigationGuide = '지팡이 연결이 끊어져 음성 안내를 종료했습니다.';
            _upcomingNavigationGuide = '';
            _navigationDistanceText = '-';
            _navigationMotorStatus = 'BLE 연결 끊김';
            _navigationMotorVisualTimer?.cancel();
            _activeNavigationMotorAction = '';
          });

          // 사용자가 직접 끊은 게 아니면 자동으로 다시 연결을 시도한다.
          if (!_userDisconnected) {
            unawaited(_scheduleReconnect());
          }
        }
      });

      try {
        await device.connect(
          license: License.nonprofit,
          timeout: const Duration(seconds: 15),
        );
      } catch (e) {
        // Some versions report an error if the device is already connected.
        final String message = e.toString().toLowerCase();
        if (!message.contains('already') &&
            !message.contains('connected')) {
          rethrow;
        }
      }

      try {
        await device.requestMtu(512);
      } catch (e) {
        print('BLE MTU request skipped: $e');
      }

      setState(() {
        _bleStatus = 'SmartCane 서비스 확인 중...';
      });

      final List<BluetoothService> services =
          await device.discoverServices();

      BluetoothCharacteristic? targetCharacteristic;

      for (final BluetoothService service in services) {
        if (service.uuid.toString().toLowerCase() !=
            _bleServiceUuid.toLowerCase()) {
          continue;
        }

        for (final BluetoothCharacteristic characteristic
            in service.characteristics) {
          if (characteristic.uuid.toString().toLowerCase() ==
              _bleCharacteristicUuid.toLowerCase()) {
            targetCharacteristic = characteristic;
            break;
          }
        }
      }

      if (targetCharacteristic == null) {
        throw Exception(
          'SmartCane BLE Characteristic을 찾지 못했습니다.\n'
          'Service: $_bleServiceUuid\n'
          'Characteristic: $_bleCharacteristicUuid',
        );
      }

      setState(() {
        _bleStatus = 'SmartCane Notify 설정 중...';
      });

      _bleNotifySubscription =
          targetCharacteristic.onValueReceived.listen(
        _handleBleNotification,
        onError: (Object error) {
          print('BLE Notify error: $error');
        },
      );

      if (targetCharacteristic.properties.notify ||
          targetCharacteristic.properties.indicate) {
        await targetCharacteristic.setNotifyValue(true);
      }

      if (!mounted) return;

      setState(() {
        _bleCharacteristic = targetCharacteristic;
        _isBleConnected = true;
        _bleStatus = 'SmartCane 연결됨';
        _navigationMotorStatus = '진동 안내 대기';
        _navigationMotorVisualTimer?.cancel();
        _activeNavigationMotorAction = '';
      });

      print('Bluetooth LE connection successful');
      _recordAppLog(
        'connection',
        _isAutoReconnecting ? '지팡이 자동 재연결 성공' : '지팡이 연결됨 ($_bleDeviceId)',
      );
      print('Service UUID: $_bleServiceUuid');
      print('Characteristic UUID: $_bleCharacteristicUuid');
      print('BLE Notify listener ready');

      _showMessage('SmartCane BLE 연결 완료');
      _userDisconnected = false;
      if (speakConnected) {
        unawaited(
          _ttsService.speak(
            _isAutoReconnecting ? '지팡이가 다시 연결되었습니다.' : '지팡이가 연결되었습니다.',
          ),
        );
      }
      await _requestYoloClasses(waitForResponse: false);
      // 앱에 저장된 위험 감지 설정을 지팡이에 맞춘다.
      unawaited(_sendHazardAlertSettingsToPi());
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _bleCharacteristic = null;
        _isBleConnected = false;
        _bleStatus = 'SmartCane 연결 실패';
        _piHazardSettingStatus = '';
      });

      print('BLE connection error: $e');
      _showMessage('SmartCane 연결 실패: $e');
    }
  }

  Future<bool> _requestYoloClasses({
    bool waitForResponse = true,
  }) async {
    if (!_isBleConnected || _bleCharacteristic == null) return false;
    if (_yoloClasses.isNotEmpty) return true;

    try {
      await _writeBleText('GET_CLASSES');
      print('[APP -> PI] GET_CLASSES');
    } catch (e) {
      print('YOLO 클래스 목록 요청 실패: $e');
      return false;
    }

    if (!waitForResponse) return true;

    for (int attempt = 0; attempt < 15; attempt += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (_yoloClasses.isNotEmpty) return true;
    }

    return false;
  }

  void _handleBleNotification(List<int> bytes) {
    try {
      if (bytes.isEmpty) {
        print('BLE Notify: empty value');
        return;
      }

      final String message = utf8.decode(
        bytes,
        allowMalformed: true,
      );

      print('');
      print('================================');
      print('[PI -> APP]');
      print(message);
      print('================================');

      if (!mounted) return;

      _recordBleLog(toPi: false, raw: message);

      Map<String, dynamic>? statusJson;
      Map<String, dynamic>? hazardJson;
      Map<String, dynamic>? objectJson;
      Map<String, dynamic>? navigationMotorJson;
      Map<String, dynamic>? objectClassesJson;
      Map<String, dynamic>? hazardSettingJson;

      try {
        final dynamic decoded = jsonDecode(message);

        if (decoded is Map<String, dynamic>) {
          final String type =
              decoded['type']?.toString().trim().toLowerCase() ?? '';

          if (type == 'status') {
            statusJson = decoded;
          } else if (type == 'hazard') {
            hazardJson = decoded;
          } else if (type == 'object') {
            objectJson = decoded;
          } else if (type == 'navigation_motor') {
            navigationMotorJson = decoded;
          } else if (type == 'object_classes') {
            objectClassesJson = decoded;
          } else if (type == 'hazard_setting') {
            hazardSettingJson = decoded;
          }
        }
      } catch (_) {
        // HELLO FROM PI, PONG FROM PI, etc.
      }

      if (hazardSettingJson != null) {
        _handleHazardSettingAck(hazardSettingJson);
        return;
      }

      // 지팡이가 아직 HAZARD 명령을 반영하기 전에 도착한 패킷에도 앱 설정을 적용한다.
      if (hazardJson != null) {
        hazardJson = _applyHazardAlertSettings(hazardJson);
      }

      if (objectJson != null) {
        final String receivedTarget =
            objectJson['target']?.toString().trim().toLowerCase() ?? '';
        final String activeTarget = _activeObjectTarget.trim().toLowerCase();

        // STOP/초기화/새 탐색 이후 늦게 도착한 이전 객체 알림은 무시한다.
        if (activeTarget.isEmpty ||
            (receivedTarget.isNotEmpty && receivedTarget != activeTarget)) {
          print(
            '[PI -> APP] stale object ignored: '
            'received=$receivedTarget, active=$activeTarget',
          );
          objectJson = null;
        }
      }

      final String? objectAnnouncement = objectJson == null
          ? null
          : _buildObjectAnnouncement(objectJson);
      final String? hazardTitle =
          hazardJson == null ? null : _buildHazardTitle(hazardJson);
      final String? hazardDetails =
          hazardJson == null ? null : _buildHazardDetails(hazardJson);

      if (objectClassesJson != null) {
        _handleYoloClassChunk(objectClassesJson);
        return;
      }

      setState(() {
        if (statusJson != null) {
          double? asDouble(dynamic value) {
            if (value is num) return value.toDouble();
            return double.tryParse(value?.toString() ?? '');
          }

          _piBattery = asDouble(statusJson['battery']);
          _piCharging = statusJson['charging']?.toString() ?? '-';
          _piWarning = statusJson['warning']?.toString() ?? '';
          _piStatusUpdatedAt = DateTime.now();
        }

        if (navigationMotorJson != null) {
          final String action =
              navigationMotorJson['action']?.toString() ?? '-';
          final String state =
              navigationMotorJson['state']?.toString() ?? '-';
          _navigationMotorStatus =
              '${_navigationMotorLabel(action)} · $state';
          final String normalizedAction = action.trim().toUpperCase();
          final String normalizedState = state.trim().toLowerCase();
          _activeNavigationMotorAction =
              normalizedAction == 'STOP' ||
                      normalizedState == 'stopped' ||
                      normalizedState == 'stop' ||
                      normalizedState == 'off'
                  ? ''
                  : normalizedAction;
          _scheduleNavigationMotorVisualClear(_activeNavigationMotorAction);
        }

        if (objectAnnouncement != null) {
          _lastObjectDisplayTitle = _buildObjectDetectionTitle(objectJson!);
          _lastObjectDisplaySubtitle = objectAnnouncement;
          _activeObjectMotorDirection =
              objectJson['direction']?.toString().trim().toUpperCase() ?? '';
          _scheduleObjectMotorVisualClear(_activeObjectMotorDirection);

          if (!_hazardDisplayActive) {
            _statusTitle = _lastObjectDisplayTitle;
            _statusSubtitle = _lastObjectDisplaySubtitle;
          }
        }

        if (hazardJson != null && hazardTitle != null) {
          final String hazardState =
              hazardJson['state']?.toString().trim().toLowerCase() ?? '';
          _hazardDisplayActive = hazardState == 'detected';

          if (_hazardDisplayActive || _lastObjectDisplayTitle.isEmpty) {
            _statusTitle = hazardTitle;
            _statusSubtitle =
                hazardDetails ?? '주변 장애물 정보를 확인하세요.';
          } else {
            _statusTitle = _lastObjectDisplayTitle;
            _statusSubtitle = _lastObjectDisplaySubtitle;
          }
        }
      });

      if (statusJson != null) {
        unawaited(_maybeAnnounceBattery());
      }

      if (objectJson != null) {
        unawaited(_speakObjectAnnouncement(objectJson));
      }

      if (hazardJson != null) {
        unawaited(_speakHazardAnnouncement(hazardJson));
      }
    } catch (e) {
      print('BLE Notify 처리 오류: $e');
    }
  }

  void _handleYoloClassChunk(Map<String, dynamic> data) {
    final String state = data['state']?.toString() ?? '';

    if (state == 'not_ready') {
      setState(() {
        _yoloClasses = <String>[];
        _bleStatus = 'SmartCane 연결됨 · YOLO 준비 중';
      });
      return;
    }

    final int? index = data['index'] is num
        ? (data['index'] as num).toInt()
        : int.tryParse(data['index']?.toString() ?? '');
    final int? total = data['total'] is num
        ? (data['total'] as num).toInt()
        : int.tryParse(data['total']?.toString() ?? '');
    final dynamic rawClasses = data['classes'];
    final String batch = data['batch']?.toString() ?? '';

    if (index == null ||
        total == null ||
        index < 0 ||
        total <= 0 ||
        index >= total ||
        rawClasses is! List ||
        batch.isEmpty) {
      print('잘못된 YOLO 클래스 조각: $data');
      return;
    }

    if (_yoloClassBatch != batch) {
      _yoloClassChunks.clear();
      _expectedYoloClassChunks = total;
      _yoloClassBatch = batch;
    }

    _yoloClassChunks[index] = rawClasses
        .map((dynamic value) => value.toString().trim())
        .where((String value) => value.isNotEmpty)
        .toList();

    if (_yoloClassChunks.length != _expectedYoloClassChunks) return;

    final List<String> receivedClasses = <String>[];
    for (int chunkIndex = 0;
        chunkIndex < _expectedYoloClassChunks;
        chunkIndex += 1) {
      final List<String>? chunk = _yoloClassChunks[chunkIndex];
      if (chunk == null) return;
      receivedClasses.addAll(chunk);
    }

    final List<String> uniqueClasses = receivedClasses.toSet().toList();

    setState(() {
      _yoloClasses = uniqueClasses;
      _bleStatus = 'SmartCane 연결됨';
    });

    // YOLO 클래스 수는 내부 로그로만 확인하고 사용자 UI에는 표시하지 않는다.
    print('YOLO classes received: ${_yoloClasses.length}');
  }

  String _objectDisplayName(String target) {
    if (_activeObjectTarget.toLowerCase() == target.toLowerCase() &&
        _activeObjectLabel.trim().isNotEmpty) {
      return _activeObjectLabel.trim();
    }

    return target;
  }

  String _directionLabel(String direction) {
    const Map<String, String> labels = {
      'TOP': '위쪽',
      'BOTTOM': '아래쪽',
      'LEFT': '왼쪽',
      'RIGHT': '오른쪽',
      'TOP+LEFT': '왼쪽 위',
      'TOP+RIGHT': '오른쪽 위',
      'BOTTOM+LEFT': '왼쪽 아래',
      'BOTTOM+RIGHT': '오른쪽 아래',
      'CENTER': '정면 중앙',
    };

    return labels[direction.toUpperCase()] ?? direction;
  }

  String _objectDetectionDirection(String direction) {
    final String normalized = direction.trim().toUpperCase();

    if (normalized.contains('LEFT')) return '왼쪽';
    if (normalized.contains('RIGHT')) return '오른쪽';
    if (normalized == 'TOP') return '위쪽';
    if (normalized == 'BOTTOM') return '아래쪽';
    if (normalized == 'CENTER') return '정면';

    return _directionLabel(normalized);
  }

  String _buildObjectDetectionTitle(Map<String, dynamic> data) {
    final String direction = data['direction']?.toString().trim() ?? '';

    if (direction.isEmpty) return '물체 감지';

    return '${_objectDetectionDirection(direction)} 물체 감지';
  }

  Future<void> _loadHazardAlertSettings() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final bool enabled = prefs.getBool(_prefHazardAlertEnabled) ?? true;
      // 방향별 값이 없으면 예전 단일 거리(모든 방향 공통 상한)를 기본값과 비교해 옮겨 쓴다.
      final double? legacyDistance = prefs.getDouble(_prefHazardAlertDistanceCm);
      final Map<String, double> distances = <String, double>{
        for (final MapEntry<String, double> entry
            in _hazardDirectionDefaultCm.entries)
          entry.key: _clampHazardDistance(
            entry.key,
            prefs.getDouble('$_prefHazardAlertDistancePrefix${entry.key}') ??
                legacyDistance ??
                entry.value,
          ),
      };
      if (!mounted) return;
      setState(() {
        _hazardAlertEnabled = enabled;
        _hazardAlertDistanceCm.addAll(distances);
      });
      print(
        '[HAZARD SETTING] loaded enabled=$enabled ${_hazardDistanceSummary()}',
      );
    } catch (error) {
      print('위험 감지 설정 불러오기 오류: $error');
    }
  }

  Future<void> _saveHazardAlertSettings() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefHazardAlertEnabled, _hazardAlertEnabled);
      for (final MapEntry<String, double> entry
          in _hazardAlertDistanceCm.entries) {
        await prefs.setDouble(
          '$_prefHazardAlertDistancePrefix${entry.key}',
          entry.value,
        );
      }
    } catch (error) {
      print('위험 감지 설정 저장 오류: $error');
    }
  }

  void _setHazardAlertEnabled(bool enabled) {
    setState(() {
      _hazardAlertEnabled = enabled;
      if (!enabled) {
        _clearHazardDisplay();
      }
    });
    print('[HAZARD SETTING] enabled=$enabled');
    unawaited(_saveHazardAlertSettings());
    unawaited(_sendHazardAlertSettingsToPi());
  }

  /// 1cm 단위로 반올림하고 [최소 10cm, 그 방향 기본값] 안으로 맞춘다.
  double _clampHazardDistance(String direction, double distanceCm) {
    return distanceCm
        .roundToDouble()
        .clamp(_hazardAlertDistanceMinCm, _hazardDirectionDefaultCm[direction]!)
        .toDouble();
  }

  /// 슬라이더를 끄는 중에는 화면 값만 바꾸고, 손을 뗄 때 [_commitHazardAlertDistance]로 저장·전송한다.
  void _setHazardAlertDistance(String direction, double distanceCm) {
    setState(() {
      _hazardAlertDistanceCm[direction] =
          _clampHazardDistance(direction, distanceCm);
    });
  }

  void _commitHazardAlertDistance(String direction, double distanceCm) {
    _setHazardAlertDistance(direction, distanceCm);
    print('[HAZARD SETTING] ${_hazardDistanceSummary()}');
    unawaited(_saveHazardAlertSettings());
    unawaited(_sendHazardAlertSettingsToPi());
  }

  /// +/- 버튼·직접 입력·되돌리기: 값을 적용하고 바뀐 값을 음성으로 읽어 준다.
  void _changeHazardAlertDistance(String direction, double distanceCm) {
    _commitHazardAlertDistance(direction, distanceCm);
    unawaited(_ttsService.speak(_hazardDistanceSpokenText(direction)));
  }

  void _resetAllHazardAlertDistances() {
    setState(() {
      _hazardAlertDistanceCm.addAll(_hazardDirectionDefaultCm);
    });
    print('[HAZARD SETTING] reset ${_hazardDistanceSummary()}');
    unawaited(_saveHazardAlertSettings());
    unawaited(_sendHazardAlertSettingsToPi());
    unawaited(_ttsService.speak('위험 안내 거리를 모두 지팡이 기본 기준으로 되돌렸습니다.'));
  }

  String _hazardDistanceSpokenText(String direction) {
    final String label = _hazardDirectionLabels[direction]!;
    final int distance = _hazardAlertDistanceCm[direction]!.round();
    return _isHazardDirectionLimited(direction)
        ? '$label 위험 안내 거리 $distance센티미터'
        : '$label 위험 안내 거리를 기본 기준 $distance센티미터로 되돌렸습니다.';
  }

  /// 숫자를 직접 입력받아 그 방향의 거리로 적용한다.
  Future<void> _promptHazardAlertDistance(String direction) async {
    final int? input = await showDialog<int>(
      context: context,
      builder: (BuildContext context) => _HazardDistanceInputDialog(
        label: _hazardDirectionLabels[direction]!,
        initialCm: _hazardAlertDistanceCm[direction]!.round(),
        minCm: _hazardAlertDistanceMinCm.round(),
        maxCm: _hazardDirectionDefaultCm[direction]!.round(),
      ),
    );
    if (input == null || !mounted) return;
    _changeHazardAlertDistance(direction, input.toDouble());
  }

  /// 현재 위험 감지 설정을 지팡이(Raspberry Pi)에 BLE 명령으로 보낸다.
  /// 방향별 거리 → 켜짐/꺼짐 순서로 보내므로 마지막 응답이 모든 값을 반영한다.
  Future<void> _sendHazardAlertSettingsToPi() async {
    if (!_isBleConnected || _bleCharacteristic == null) return;

    final List<String> commands = <String>[
      for (final String direction in _hazardDirectionDefaultCm.keys)
        _isHazardDirectionLimited(direction)
            ? 'HAZARD:DIST:$direction:${_hazardAlertDistanceCm[direction]!.round()}'
            : 'HAZARD:DIST:$direction:DEFAULT',
      _hazardAlertEnabled ? 'HAZARD:ON' : 'HAZARD:OFF',
    ];

    if (mounted) {
      setState(() {
        _piHazardSettingStatus = '지팡이에 적용 중...';
      });
    }

    try {
      for (final String command in commands) {
        await _writeBleTextQueued(command);
        print('[APP -> PI] $command');
      }
    } catch (error) {
      print('위험 감지 설정 전송 오류: $error');
      if (mounted) {
        setState(() {
          _piHazardSettingStatus = '지팡이 전송 실패 · 연결을 확인하세요';
        });
      }
    }
  }

  /// 지팡이가 보낸 {"type":"hazard_setting","enabled":..,"thresholds_cm":{"FRONT":..,"SIDE":..,"UPPER":..}} 처리
  void _handleHazardSettingAck(Map<String, dynamic> data) {
    final bool enabled = data['enabled'] == true;
    final dynamic rawThresholds = data['thresholds_cm'];
    final String thresholdsText =
        rawThresholds is Map ? _formatHazardThresholds(rawThresholds) : '';

    final String label;
    if (!enabled) {
      label = '지팡이 적용됨 · 위험 감지 꺼짐 (진동 경고 없음)';
    } else if (rawThresholds is! Map) {
      // 방향별 거리 명령을 모르는 예전 지팡이 코드. 방향별 거리는 앱의 화면·음성 안내에만 적용된다.
      label = '지팡이 코드 업데이트 필요 · 방향별 거리는 앱 안내에만 적용 중';
    } else {
      label = '지팡이 적용됨 · $thresholdsText 이내 감지 중';
    }

    print('[PI -> APP] hazard_setting enabled=$enabled thresholds=$rawThresholds');
    if (!mounted) return;
    setState(() {
      _piHazardSettingStatus = label;
    });
  }

  /// {"FRONT":120,"SIDE":75,"UPPER":200} → "정면 120 · 양쪽 75 · 위쪽 200cm"
  String _formatHazardThresholds(Map<dynamic, dynamic> thresholds) {
    final List<String> parts = <String>[];
    for (final String direction in _hazardDirectionDefaultCm.keys) {
      final dynamic raw = thresholds[direction];
      final num? value = raw is num ? raw : num.tryParse(raw?.toString() ?? '');
      if (value != null) {
        parts.add('${_hazardDirectionLabels[direction]} ${value.round()}');
      }
    }
    return parts.isEmpty ? '' : '${parts.join(' · ')}cm';
  }

  bool _isHazardDirectionLimited(String direction) =>
      _hazardAlertDistanceCm[direction]! < _hazardDirectionDefaultCm[direction]!;

  bool get _isHazardDistanceLimited =>
      _hazardDirectionDefaultCm.keys.any(_isHazardDirectionLimited);

  String _hazardDistanceSummary() {
    return _hazardDirectionDefaultCm.keys
        .map((String direction) =>
            '$direction=${_hazardAlertDistanceCm[direction]!.round()}cm')
        .join(' ');
  }

  /// 지팡이가 보낸 위치 이름(왼쪽/정면/오른쪽/위쪽)을 거리 설정 방향(FRONT/SIDE/UPPER)으로 바꾼다.
  String? _hazardDirectionOf(String position) {
    switch (position.trim().toUpperCase()) {
      case '정면':
      case 'FRONT':
        return 'FRONT';
      case '왼쪽':
      case '오른쪽':
      case 'LEFT':
      case 'RIGHT':
        return 'SIDE';
      case '위쪽':
      case 'UPPER':
        return 'UPPER';
    }
    return null;
  }

  /// 위험 표시를 즉시 내리고, 상태 카드가 위험 문구를 들고 있으면 중립 문구로 바꾼다.
  void _clearHazardDisplay() {
    if (!_hazardDisplayActive) return;
    _hazardDisplayActive = false;
    if (_lastObjectDisplayTitle.isNotEmpty) {
      _statusTitle = _lastObjectDisplayTitle;
      _statusSubtitle = _lastObjectDisplaySubtitle;
    } else {
      _statusTitle = '음성 인식 준비 완료';
      _statusSubtitle = '마이크에 대고 말씀해주세요.';
    }
    _resumePendingNavigationTtsAfterHazard();
  }

  /// 지팡이가 보낸 hazard 패킷에 앱의 위험 감지 설정을 적용한다.
  /// - 안내가 꺼져 있으면 null을 돌려 패킷을 무시한다. 단, 화면에 위험이 남아 있으면
  ///   한 번 '해제' 패킷으로 바꿔 표시를 내린다.
  /// - 방향별 거리를 줄였으면 그 거리 이내의 위치만 남기고, 하나도 없으면 '해제'로 바꾼다.
  Map<String, dynamic>? _applyHazardAlertSettings(Map<String, dynamic> data) {
    final String state =
        data['state']?.toString().trim().toLowerCase() ?? 'detected';

    Map<String, dynamic> cleared() => <String, dynamic>{
          'type': 'hazard',
          'state': 'cleared',
          'positions': <String>[],
          'distances_cm': <num>[],
          'filtered_by_app': true,
        };

    if (!_hazardAlertEnabled) {
      return _hazardDisplayActive ? cleared() : null;
    }

    if (state != 'detected' || !_isHazardDistanceLimited) {
      return data;
    }

    final List<String> positions = _hazardPositions(data);
    final dynamic rawDistances = data['distances_cm'];
    final List<dynamic> distances =
        rawDistances is List ? rawDistances : const [];

    final List<String> keptPositions = [];
    final List<num> keptDistances = [];
    for (int index = 0; index < positions.length; index++) {
      final dynamic raw = index < distances.length ? distances[index] : null;
      final double? distance = raw is num
          ? raw.toDouble()
          : double.tryParse(raw?.toString() ?? '');
      final String? direction = _hazardDirectionOf(positions[index]);
      // 거리값이 없거나 방향을 알 수 없는 위치는 판단할 수 없으므로 지팡이 판정을 그대로 믿는다.
      if (distance == null ||
          direction == null ||
          distance <= _hazardAlertDistanceCm[direction]!) {
        keptPositions.add(positions[index]);
        if (distance != null) keptDistances.add(distance);
      }
    }

    if (keptPositions.isEmpty) {
      return _hazardDisplayActive ? cleared() : null;
    }

    if (keptPositions.length == positions.length) return data;

    return <String, dynamic>{
      ...data,
      'positions': keptPositions,
      'distances_cm': keptDistances,
      'filtered_by_app': true,
    };
  }

  String _hazardPositionLabel(String position) {
    const Map<String, String> labels = {
      'FRONT_FAR_LEFT': '정면 왼쪽',
      'FRONT_LEFT': '정면 왼쪽',
      'LEFT': '정면 왼쪽',
      'FRONT_LEFT_CENTER': '정면 왼쪽 중앙',
      'LEFT_CENTER': '정면 왼쪽 중앙',
      'FRONT_CENTER': '정면 중앙',
      'CENTER': '정면 중앙',
      'FRONT_RIGHT_CENTER': '정면 오른쪽 중앙',
      'RIGHT_CENTER': '정면 오른쪽 중앙',
      'FRONT_RIGHT': '정면 오른쪽',
      'FRONT_FAR_RIGHT': '정면 오른쪽',
      'RIGHT': '정면 오른쪽',
      'UPPER_LEFT': '왼쪽 위쪽',
      'UPPER_CENTER': '정면 위쪽',
      'UPPER_RIGHT': '오른쪽 위쪽',
    };

    final String normalized = position.trim().toUpperCase();
    return labels[normalized] ?? position.replaceAll('_', ' ');
  }

  List<String> _hazardPositions(Map<String, dynamic> data) {
    final dynamic rawPositions = data['positions'];

    if (rawPositions is! List) return const [];

    return rawPositions
        .map((dynamic value) => value?.toString().trim() ?? '')
        .where((String value) => value.isNotEmpty)
        .toList();
  }

  String _buildHazardTitle(Map<String, dynamic> data) {
    final String state =
        data['state']?.toString().trim().toLowerCase() ?? 'detected';

    if (state != 'detected') return '위험 감지 해제';

    final List<String> positions = _hazardPositions(data);
    if (positions.isEmpty) return '주변 위험 감지';

    final List<String> labels = positions
        .map(_hazardPositionLabel)
        .toSet()
        .take(2)
        .toList();
    final int remaining = positions.length - labels.length;
    final String positionText = labels.join(' · ');
    final String moreText = remaining > 0 ? ' 외 $remaining곳' : '';

    return '$positionText$moreText 위험 감지';
  }

  String _buildHazardDetails(Map<String, dynamic> data) {
    final String state =
        data['state']?.toString().trim().toLowerCase() ?? 'detected';

    if (state != 'detected') {
      return '현재 감지 범위 안에 위험 요소가 없습니다.';
    }

    final List<String> positions = _hazardPositions(data);
    final dynamic rawDistances = data['distances_cm'];
    final List<dynamic> distances =
        rawDistances is List ? rawDistances : const [];
    final List<String> details = [];

    for (int index = 0;
        index < positions.length && index < distances.length;
        index++) {
      final double? distance = distances[index] is num
          ? (distances[index] as num).toDouble()
          : double.tryParse(distances[index]?.toString() ?? '');

      if (distance != null) {
        details.add(
          '${_hazardPositionLabel(positions[index])} ${distance.round()}cm',
        );
      }
    }

    if (details.isEmpty) return '주변 장애물과의 거리를 확인하세요.';

    return '감지 거리 · ${details.take(2).join(' / ')}';
  }

  String _buildObjectAnnouncement(Map<String, dynamic> data) {
    final String target = data['target']?.toString().trim() ?? '';
    final String direction = data['direction']?.toString().trim() ?? '';

    if (target.isEmpty || direction.isEmpty) {
      return '객체 위치 정보를 확인할 수 없습니다.';
    }

    return '${_objectDisplayName(target)} 위치는 ${_directionLabel(direction)}입니다.';
  }

  bool _isHazardTtsPriorityActive() {
    if (_hazardDisplayActive) return true;

    final DateTime? lastHazard = _lastHazardAnnouncementAt;
    if (lastHazard == null) return false;

    return DateTime.now().difference(lastHazard) < _hazardPriorityHold;
  }

  /// [holdDuringHazard]가 true면 위험 중에도 버리지 않고 별도 칸에 보류했다가
  /// 위험 해제 뒤 턴 안내보다 먼저 읽는다. (길안내 시작·멈춤·재개·취소·도착 등)
  Future<void> _speakLowerPriorityAnnouncement(
    String text, {
    bool holdDuringHazard = false,
  }) async {
    if (text.trim().isEmpty) return;

    // 위험 안내가 활성화되어 있거나 방금 출력된 경우
    // 길안내/일반 안내가 위험 경고를 덮어쓰지 않게 한다.
    if (_isHazardTtsPriorityActive()) {
      if (holdDuringHazard) {
        _pendingImportantTts = text;
        print('[APP TTS HOLD] 위험 안내 우선 · 주요 안내 보류: $text');
      } else if (_isNavigationGuidanceActive) {
        // 길안내 턴 안내는 보관하지 않는다. 위험 해제 2초 뒤 현재 위치 기준으로 다시 계산해 알린다.
        print('[APP TTS SKIP] 위험 안내 우선 · 길안내는 해제 후 재계산: $text');
      } else {
        print('[APP TTS SKIP] 위험 안내 우선: $text');
      }
      return;
    }

    _lastAnnouncementText = text;
    await _ttsService.speak(text);
  }

  bool get _isNavigationGuidanceActive =>
      _isNavigating && !_isNavigationPaused;

  /// 상태 확인·현재 위치 안내용. 읽는 동안 물건 방향 음성을 보류하고,
  /// 다 읽으면 보류해 둔 마지막 물건 방향 한 건을 이어서 읽는다.
  /// (위험 안내와 길안내 턴 안내는 더 중요하므로 그대로 끼어들 수 있다.)
  Future<void> _speakInfoAnnouncement(String text) async {
    _isInfoAnnouncementActive = true;
    try {
      // TTS 완료 콜백이 오지 않는 단말을 대비해 상한을 둔다.
      await _speakLowerPriorityAnnouncement(
        text,
        holdDuringHazard: true,
      ).timeout(
        const Duration(seconds: 15),
        onTimeout: () {},
      );
    } finally {
      _isInfoAnnouncementActive = false;
    }

    final Map<String, dynamic>? pending = _pendingObjectAnnouncement;
    _pendingObjectAnnouncement = null;
    _pendingObjectAnnouncementAt = null;
    if (pending != null && mounted && _activeObjectTarget.trim().isNotEmpty) {
      print('[APP OBJECT TTS RESUME] 상태/위치 안내 후 물건 방향 재안내');
      await _speakObjectAnnouncement(pending);
    }
  }

  /// 위험 해제 2초 뒤: 보류한 주요 안내를 먼저 읽고, 길안내 중이면
  /// 보류 여부와 상관없이 "지금 해야 할 방향"을 GPS·나침반 기준으로 다시 계산해
  /// 음성과 진동으로 한 번 더 알린다.
  void _resumePendingNavigationTtsAfterHazard() {
    final bool hasImportant = _pendingImportantTts.trim().isNotEmpty;
    if (!hasImportant && !_isNavigationGuidanceActive) return;

    final int token = ++_hazardClearToken;

    // 보류분은 여기서 꺼내지 않고 실제로 읽는 시점에 꺼낸다.
    // 2초 유예 동안 더 새로운 안내가 들어오면 그것을 읽기 위해서다.
    Future<void>.delayed(_hazardPriorityHold, () async {
      if (!mounted || token != _hazardClearToken) return;
      if (_isHazardTtsPriorityActive()) {
        // 다시 위험해졌다면 보류분을 그대로 두고 다음 해제 때 읽는다.
        return;
      }

      final String important = _pendingImportantTts;
      _pendingImportantTts = '';
      if (important.trim().isNotEmpty) {
        print('[APP TTS RESUME] 위험 해제 후 주요 안내: $important');
        _lastAnnouncementText = important;
        await _ttsService.speak(important);
        if (!mounted ||
            token != _hazardClearToken ||
            _isHazardTtsPriorityActive()) {
          return;
        }
      }

      // 위험 중 들어온 턴 안내는 버렸으므로, 지금 위치 기준으로 새로 계산해 알린다.
      await _reannounceCurrentNavigationGuidance();

      // 물건 찾기 중이면 보류해 둔 물건 방향을 다시 읽는다.
      // (지팡이는 위험 해제 직후 현재 방향을 한 번 다시 보내므로 보통 그 값이 읽힌다.)
      await _reannouncePendingObjectDirection();
    });
  }

  /// 위험 해제 뒤 물건 방향 재안내. 진동은 지팡이가 해제 직후 스스로 다시 출력한다.
  Future<void> _reannouncePendingObjectDirection() async {
    if (!mounted || _activeObjectTarget.trim().isEmpty) return;

    final Map<String, dynamic>? pending = _pendingObjectAnnouncement;
    final DateTime? pendingAt = _pendingObjectAnnouncementAt;
    _pendingObjectAnnouncement = null;
    _pendingObjectAnnouncementAt = null;
    if (pending == null || pendingAt == null) return;

    // 너무 오래된 방향은 물건을 이미 놓쳤을 수 있으므로 읽지 않는다.
    if (DateTime.now().difference(pendingAt) > _pendingObjectAnnouncementMaxAge) {
      print('[APP OBJECT TTS DROP] 위험 해제 후 재안내 · 오래된 방향이라 생략');
      return;
    }

    print('[APP OBJECT TTS RESUME] 위험 해제 후 물건 방향 재안내');
    await _speakObjectAnnouncement(pending, force: true);
  }

  /// 지금 단계의 방향 안내를 최신 GPS 위치·방향으로 다시 계산해
  /// 음성과 진동으로 한 번 알린다. 위치를 아직 못 받았으면 마지막 안내 문구를 쓴다.
  Future<void> _reannounceCurrentNavigationGuidance() async {
    if (!_isNavigationGuidanceActive ||
        _navigationSteps.isEmpty ||
        _currentNavigationStepIndex >= _navigationSteps.length) {
      return;
    }

    final Position? position = _latestNavigationPosition;
    final double? heading = _currentTravelHeading;
    String guide = _navigationGuide;
    String motorAction = _turnNavigationMotorActionAtStep(
      _currentNavigationStepIndex,
    );

    if (position != null && heading != null) {
      final KakaoNavigationStep step =
          _navigationSteps[_currentNavigationStepIndex];
      final double distance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        step.latitude,
        step.longitude,
      );
      final double targetBearing = _targetBearingForStep(position, step);
      final String instruction = _relativeDirectionInstruction(
        heading,
        targetBearing,
      );
      guide = _currentGuideForStep(
        _currentNavigationStepIndex,
        instruction,
        distance.round(),
      );
      motorAction = _relativeNavigationMotorAction(heading, targetBearing);
      _lastDirectionAnnouncementKey = instruction;
    }

    _lastDirectionAnnouncementAt = DateTime.now();
    if (mounted) {
      setState(() {
        _navigationGuide = guide;
      });
    }

    print('[NAV] 위험 해제 후 현재 방향 재안내: $motorAction · $guide');
    _recordAppLog('navigation', '위험 해제 후 현재 방향 재안내: $guide');

    await _sendNavigationMotorCommand(motorAction, force: true);
    await _speakLowerPriorityAnnouncement(guide);
  }

  /// [force]면 위험 해제 뒤 재안내처럼 반복 억제 규칙을 건너뛰고 바로 읽는다.
  Future<void> _speakObjectAnnouncement(
    Map<String, dynamic> data, {
    bool force = false,
  }) async {
    final String target = data['target']?.toString().trim() ?? '';
    final String direction = data['direction']?.toString().trim() ?? '';

    if (target.isEmpty || direction.isEmpty) return;

    // TTS 우선순위: 위험 > 길안내/일반 안내 > 객체 찾기
    // (물건 찾기 때문에 길안내가 잠시 멈춘 동안에는 객체 안내를 말한다.)
    if (_isNavigationGuidanceActive) {
      print('[APP OBJECT TTS SKIP] 길안내 우선');
      return;
    }

    // 위험 중이거나 상태·현재 위치를 읽는 중이면 끊지 않고 마지막 방향만 보류한다.
    // 위험 해제 2초 뒤에 보류한 방향을 다시 읽는다.
    if (_isHazardTtsPriorityActive() || _isInfoAnnouncementActive) {
      _pendingObjectAnnouncement = data;
      _pendingObjectAnnouncementAt = DateTime.now();
      print('[APP OBJECT TTS HOLD] 위험 또는 상태/위치 안내 중 · 보류');
      return;
    }

    final DateTime now = DateTime.now();
    final String key = '${target.toLowerCase()}:${direction.toUpperCase()}';
    final DateTime? previous = _lastObjectAnnouncementAt;

    if (!force && previous != null) {
      final Duration elapsed = now.difference(previous);

      // Suppress rapid announcements caused by a bounding box crossing grid
      // boundaries. Repeat the exact same guidance less frequently.
      if (elapsed < const Duration(milliseconds: 1500)) return;
      if (key == _lastObjectAnnouncementKey &&
          elapsed < const Duration(seconds: 5)) {
        return;
      }
    }

    final String announcement = _buildObjectAnnouncement(data);
    print('[APP TTS] $announcement');
    await _speakLowerPriorityAnnouncement(announcement);

    // 위험/길안내 때문에 실제 객체 안내가 보류된 경우에는
    // '방금 안내했다'고 기록하지 않는다.
    if (!_isHazardTtsPriorityActive() && !_isNavigationGuidanceActive) {
      _lastObjectAnnouncementAt = DateTime.now();
      _lastObjectAnnouncementKey = key;
    }
  }

  Future<void> _speakHazardAnnouncement(Map<String, dynamic> data) async {
    final String state =
        data['state']?.toString().trim().toLowerCase() ?? 'detected';

    if (state != 'detected') {
      // 위험이 해제되면 같은 위험 key만 비운다.
      // 마지막 안내 시각은 남겨서 위험 직후 다른 TTS가 바로 덮지 않게 한다.
      _lastHazardAnnouncementKey = '';
      _resumePendingNavigationTtsAfterHazard();
      return;
    }

    final List<String> positions = _hazardPositions(data);
    if (positions.isEmpty) return;

    final String key =
        positions.map((String value) => value.toUpperCase()).join('|');
    final DateTime now = DateTime.now();
    final DateTime? previous = _lastHazardAnnouncementAt;

    if (previous != null) {
      final Duration elapsed = now.difference(previous);

      // 센서 값이 CENTER -> LEFT -> CENTER처럼 흔들려도
      // 모든 위험 TTS 사이에 최소 2.5초 간격을 둔다.
      if (elapsed < _hazardGlobalTtsInterval) {
        return;
      }

      // 같은 위치 조합의 위험은 5초에 한 번만 반복한다.
      if (key == _lastHazardAnnouncementKey &&
          elapsed < _hazardSameTtsInterval) {
        return;
      }
    }

    _lastHazardAnnouncementAt = now;
    _lastHazardAnnouncementKey = key;

    final String positionText = positions
        .map(_hazardPositionLabel)
        .toSet()
        .take(2)
        .join(', ');
    final String announcement = '$positionText 장애물 주의';

    print('[APP HAZARD TTS] $announcement');

    // 위험 안내는 최우선이다.
    // 길안내/객체 안내가 재생 중이면 즉시 중단하고 위험 안내를 출력한다.
    try {
      await _ttsService.stop();
    } catch (error) {
      print('위험 TTS 전 기존 음성 중지 오류: $error');
    }

    await _ttsService.speak(announcement);
  }

  Future<void> _announceSmartCaneStatus({
    required int commandEpoch,
  }) async {
    if (!mounted || commandEpoch != _commandEpoch) return;

    // BLE 자체가 연결되지 않은 경우.
    if (!_isBleConnected) {
      setState(() {
        _statusTitle = 'SmartCane 연결 안 됨';
        _statusSubtitle =
            '지팡이가 스마트폰과 연결되어 있지 않습니다. 설정에서 연결해주세요.';
      });

      await _speakInfoAnnouncement(
        '지팡이가 스마트폰과 연결되어 있지 않습니다. 설정에서 연결해주세요.',
      );
      return;
    }

    // BLE 연결은 됐지만 status 패킷을 아직 한 번도 받지 못한 경우.
    if (_piStatusUpdatedAt == null) {
      setState(() {
        _statusTitle = 'SmartCane 상태 수신 대기';
        _statusSubtitle =
            '지팡이는 연결되어 있지만 상태 정보를 아직 받지 못했습니다.';
      });

      await _speakInfoAnnouncement(
        '지팡이는 연결되어 있지만 상태 정보를 아직 받지 못했습니다.',
      );
      return;
    }

    final String batteryText = _piBattery == null
        ? '배터리 정보 없음'
        : '배터리 ${_piBattery!.round()}퍼센트';

    final String chargingText = _chargingLabel();

    // 사용자에게 필요한 핵심 정보만 간단하게 안내한다.
    // 내부 센서/카메라/전원 진단 정보는 사용자용 상태 화면에 노출하지 않는다.
    setState(() {
      _statusTitle = 'SmartCane 연결됨';
      _statusSubtitle = '$batteryText · $chargingText';
    });
    _recordAppLog('status', '상태 안내: $batteryText · $chargingText');

    final StringBuffer speech = StringBuffer();
    speech.write('지팡이가 정상적으로 연결되어 있습니다. ');

    if (_piBattery != null) {
      speech.write('배터리는 ${_piBattery!.round()}퍼센트이고, ');
    }

    switch (_piCharging.toLowerCase()) {
      case 'charging':
        speech.write('현재 충전 중입니다. ');
        break;
      case 'not_charging':
        speech.write('현재 충전 중이 아닙니다. ');
        break;
      case 'disabled':
        speech.write('현재 충전이 중지된 상태입니다. ');
        break;
      default:
        // 알 수 없는 충전 상태는 음성에서 굳이 읽지 않는다.
        break;
    }

    await _speakInfoAnnouncement(speech.toString());
  }

  String _chargingLabel() {
    switch (_piCharging.toLowerCase()) {
      case 'charging':
        return '충전 중';
      case 'not_charging':
        return '충전 안 함';
      case 'disabled':
        return '충전 중지';
      case 'unknown':
        return '알 수 없음';

      // Compatibility with older Raspberry Pi test code.
      case 'enabled':
        return '충전 가능';

      default:
        return _piCharging.isEmpty ? '알 수 없음' : _piCharging;
    }
  }

  String _statusUpdatedLabel() {
    final DateTime? updated = _piStatusUpdatedAt;
    if (updated == null) return '상태 수신 대기 중';

    final String hh = updated.hour.toString().padLeft(2, '0');
    final String mm = updated.minute.toString().padLeft(2, '0');
    final String ss = updated.second.toString().padLeft(2, '0');

    return '마지막 업데이트 $hh:$mm:$ss';
  }

  Future<void> _writeBleText(String text) async {
    final BluetoothCharacteristic? characteristic =
        _bleCharacteristic;

    if (!_isBleConnected || characteristic == null) {
      throw Exception('SmartCane BLE가 연결되어 있지 않습니다.');
    }

    final List<int> data = utf8.encode(text);
    _recordBleLog(toPi: true, raw: text);

    if (characteristic.properties.write) {
      await characteristic.write(
        data,
        withoutResponse: false,
      );
    } else if (characteristic.properties.writeWithoutResponse) {
      await characteristic.write(
        data,
        withoutResponse: true,
      );
    } else {
      throw Exception('BLE Characteristic이 Write를 지원하지 않습니다.');
    }
  }

  Future<void> _writeBleTextQueued(String text) {
    final Completer<void> completer = Completer<void>();

    _bleWriteQueue = _bleWriteQueue
        .catchError((Object _) {
          // 이전 BLE 쓰기가 실패해도 다음 명령은 계속 처리한다.
        })
        .then((_) async {
          try {
            await _writeBleText(text);
            if (!completer.isCompleted) {
              completer.complete();
            }
          } catch (error, stackTrace) {
            if (!completer.isCompleted) {
              completer.completeError(error, stackTrace);
            }
          }
        });

    return completer.future;
  }

  Future<void> _sendNavigationMotorCommand(
    String action, {
    bool force = false,
  }) async {
    final String normalizedAction = action.trim().toUpperCase();
    const Set<String> allowedActions = {
      'FORWARD',
      'LEFT',
      'RIGHT',
      'UTURN',
      'STOP',
    };

    if (!allowedActions.contains(normalizedAction)) return;
    if (!_isBleConnected || _bleCharacteristic == null) return;

    // 일반 방향 명령은 중복 전송을 막되 STOP은 절대 버리지 않는다.
    if (_isSendingNavigationToPi && normalizedAction != 'STOP') return;

    if (!force) {
      if (normalizedAction != _pendingNavigationBleCommand) {
        _pendingNavigationBleCommand = normalizedAction;
        _pendingNavigationBleCount = 1;
        return;
      }

      _pendingNavigationBleCount += 1;
      if (_pendingNavigationBleCount < 2) return;
    }

    final DateTime now = DateTime.now();
    final bool isSameAction =
        normalizedAction == _lastNavigationBleCommand;
    final bool repeatIntervalFinished = _lastNavigationBleCommandAt == null ||
        now.difference(_lastNavigationBleCommandAt!) >=
            _navigationRepeatInterval;

    // 같은 방향이라도 일정 시간이 지나면 진동 명령을 다시 보낸다.
    if (!force && isSameAction && !repeatIntervalFinished) {
      return;
    }

    try {
      _isSendingNavigationToPi = true;
      final String command = 'NAV:$normalizedAction';
      await _writeBleTextQueued(command);
      _lastNavigationBleCommand = normalizedAction;
      _lastNavigationBleCommandAt = DateTime.now();
      _pendingNavigationBleCommand = normalizedAction;
      _pendingNavigationBleCount = 0;
      if (mounted) {
        setState(() {
          _navigationMotorStatus =
              '${_navigationMotorLabel(normalizedAction)} 전송 완료';
          _activeNavigationMotorAction =
              normalizedAction == 'STOP' ? '' : normalizedAction;
          _scheduleNavigationMotorVisualClear(_activeNavigationMotorAction);
        });
      }
      print('[APP -> PI] $command');
    } catch (error) {
      print('길안내 진동 명령 전송 오류: $error');
    } finally {
      _isSendingNavigationToPi = false;
    }
  }

  void _scheduleNavigationMotorVisualClear(String action) {
    _navigationMotorVisualTimer?.cancel();

    final String normalized = action.trim().toUpperCase();
    final Duration? duration = switch (normalized) {
      // 실제 진동보다 화면 강조를 조금 더 길게 유지해
      // 어느 위치의 모터가 울렸는지 화면에서 바로 확인할 수 있게 한다.
      'FORWARD' => const Duration(milliseconds: 900),
      'LEFT' => const Duration(milliseconds: 1000),
      'RIGHT' => const Duration(milliseconds: 1000),
      'UTURN' => const Duration(milliseconds: 1200),
      _ => null,
    };

    if (duration == null) return;

    // 실제 모터는 더 짧게 울릴 수 있지만, 화면 표시는 데모 가독성을 위해
    // 최소 약 0.9초 이상 유지한다. 다음 방향 명령이 오면 즉시 새 방향으로 바뀐다.
    _navigationMotorVisualTimer = Timer(duration, () {
      if (!mounted || _activeNavigationMotorAction != normalized) return;
      setState(() {
        _activeNavigationMotorAction = '';
      });
    });
  }

  String _navigationMotorLabel(String action) {
    switch (action.trim().toUpperCase()) {
      case 'FORWARD':
        return '앞쪽 모터(직진)';
      case 'LEFT':
        return '왼쪽 모터';
      case 'RIGHT':
        return '오른쪽 모터';
      case 'UTURN':
        return '뒤쪽 모터(뒤로 돌기)';
      case 'STOP':
        return '진동 정지';
      default:
        return action;
    }
  }

  Future<void> _disconnectSmartCane() async {
    final BluetoothDevice? device = _bleDevice;

    if (device == null) return;

    // 사용자가 직접 해제한 경우에는 자동 재연결하지 않는다.
    _userDisconnected = true;
    print('[BLE] manual disconnect by user');
    unawaited(_ttsService.speak('지팡이 연결을 해제했습니다.'));

    try {
      final BluetoothCharacteristic? characteristic =
          _bleCharacteristic;

      if (characteristic != null &&
          (characteristic.properties.notify ||
              characteristic.properties.indicate)) {
        try {
          await characteristic.setNotifyValue(false);
        } catch (_) {}
      }

      await _bleNotifySubscription?.cancel();
      _bleNotifySubscription = null;

      await device.disconnect();

      if (!mounted) return;

      await _stopAllAudioOutput(stopSpeechRecognition: false);
      await _stopNavigation(resetGuide: true);

      if (!mounted) return;

      setState(() {
        _bleCharacteristic = null;
        _isBleConnected = false;
        _bleStatus = 'SmartCane 연결 끊김';
        _hazardDisplayActive = false;
        _lastObjectDisplayTitle = '';
        _lastObjectDisplaySubtitle = '';
        _lastNavigationBleCommand = '';
        _lastNavigationBleCommandAt = null;
        _pendingNavigationBleCommand = '';
        _pendingNavigationBleCount = 0;
        _navigationGuide = 'SmartCane 연결이 해제되어 음성 안내를 종료했습니다.';
        _upcomingNavigationGuide = '';
        _navigationDistanceText = '-';
        _navigationMotorStatus = 'BLE 연결 끊김';
        _navigationMotorVisualTimer?.cancel();
        _activeNavigationMotorAction = '';
      });

      _showMessage('SmartCane 연결을 해제했습니다.');
    } catch (e) {
      print('BLE disconnect error: $e');
      _showMessage('BLE 연결 해제 오류: $e');
    }
  }

  Future<void> _handleHardwareCancel() async {
    final bool wasNavigation =
        _isNavigating ||
        _isFindingRoute ||
        _isRerouting ||
        _routePoints.isNotEmpty ||
        _navigationSteps.isNotEmpty;

    final bool wasObjectSearch =
        _activeObjectTarget.trim().isNotEmpty;

    final bool wasVoiceWork =
        _isListening || _isAnalyzing;

    final bool hasActiveWork =
        wasNavigation || wasObjectSearch || wasVoiceWork;

    print(
      '[HARDWARE CANCEL] '
      'navigation=$wasNavigation, '
      'object=$wasObjectSearch, '
      'voice=$wasVoiceWork',
    );

    if (!hasActiveWork) {
      return;
    }

    // 가장 먼저 모든 비동기 명령 결과를 무효화한다.
    _commandEpoch += 1;
    _autoAnalyzeStarted = true;

    // 화면보다 실제 기능 중지를 먼저 수행한다.
    // STT/TTS를 모두 즉시 정지한다.
    try {
      await _speech.cancel();
    } catch (error) {
      print('하드웨어 취소 중 STT cancel 오류: $error');
      try {
        await _speech.stop();
      } catch (_) {}
    }

    try {
      await _ttsService.stop();
    } catch (error) {
      print('하드웨어 취소 중 TTS 중지 오류: $error');
    }

    // GPS 길안내 스트림은 즉시 끊는다.
    await _navigationPositionSubscription?.cancel();
    _navigationPositionSubscription = null;

    // 앱 내부 상태와 상관없이 Raspberry Pi에 실제 정지 명령을 강제로 보낸다.
    // STOP       : 객체 탐색 중지
    // NAV:STOP   : 길안내 진동 중지
    if (_isBleConnected && _bleCharacteristic != null) {
      try {
        print('[APP -> PI] STOP (hardware cancel)');
        await _writeBleTextQueued('STOP');
      } catch (error) {
        print('하드웨어 취소 STOP 전송 오류: $error');
      }

      try {
        print('[APP -> PI] NAV:STOP (hardware cancel)');
        await _writeBleTextQueued('NAV:STOP');
      } catch (error) {
        print('하드웨어 취소 NAV:STOP 전송 오류: $error');
      }
    }

    // 늦게 실행 중이던 기존 helper가 다시 상태를 건드리지 않도록
    // 실제 정지 명령 후 내부 상태를 한 번에 초기화한다.
    _routePoints = [];

    if (_kakaoMapReady) {
      try {
        await _kakaoMapController.runJavaScript('clearRoute();');
      } catch (error) {
        print('하드웨어 취소 지도 정리 오류: $error');
      }
    }

    if (!mounted) return;

    setState(() {
      _selectedTabIndex = 0;

      _recognizedText = '';
      _analysisResult = IntentAnalysisResult.empty();

      _isListening = false;
      _isAnalyzing = false;
      _isFindingRoute = false;
      _isRerouting = false;
      _isNavigating = false;
      _isNavigationPaused = false;
      _isSendingNavigationToPi = false;

      _activeObjectTarget = '';
      _activeObjectLabel = '';
      _activeObjectMotorDirection = '';
      _objectMotorVisualTimer?.cancel();
      _lastObjectAnnouncementAt = null;
      _lastObjectAnnouncementKey = '';
      _pendingObjectAnnouncement = null;
      _pendingObjectAnnouncementAt = null;
      _lastObjectDisplayTitle = '';
      _lastObjectDisplaySubtitle = '';

      _navigationSteps = [];
      _currentNavigationStepIndex = 0;
      _lastDistanceAnnouncementBucket = -1;
      _offRouteConsecutiveCount = 0;
      _previousRouteProgressPosition = null;
      _reverseDirectionConsecutiveCount = 0;
      _lastReverseDirectionAnnouncementAt = null;
      _previousNavigationPosition = null;
      _latestNavigationPosition = null;
      _currentTravelHeading = null;
      _lastCompassGuidanceAt = null;
      _lastDirectionAnnouncementKey = '';
      _lastDirectionAnnouncementAt = null;
      _arrivalApproachAnnounced = false;
      _arrivalDirectionAnnounced = false;
      _pendingImportantTts = '';

      _routeDestinationLongitude = null;
      _routeDestinationLatitude = null;
      _routeDestinationName = '-';
      _routeSummary = '-';
      _routeFirstGuide = '-';
      _routeTotalDistance = 0;
      _routeTotalTime = 0;
      _navigationGuide =
          '경로를 검색하면 음성 안내가 시작됩니다.';
      _upcomingNavigationGuide = '';
      _navigationDistanceText = '-';
      _navigationMotorStatus = '진동 정지';
      _navigationMotorVisualTimer?.cancel();
      _activeNavigationMotorAction = '';

      if (!_hazardDisplayActive) {
        _statusTitle = '기능 취소 완료';

        if (wasNavigation && wasObjectSearch) {
          _statusSubtitle =
              '길안내와 물건 찾기를 모두 종료했습니다.';
        } else if (wasNavigation) {
          _statusSubtitle = '길안내를 종료했습니다.';
        } else if (wasObjectSearch) {
          _statusSubtitle = '물건 찾기를 종료했습니다.';
        } else {
          _statusSubtitle = '음성 명령을 취소했습니다.';
        }
      }
    });

    // 취소 완료 안내는 위험/길안내 우선순위 helper를 거치지 않고
    // 직접 TTS로 출력한다.
    //
    // 이유:
    // 하드웨어 취소 직후에는 _isNavigating, hazard priority hold,
    // pending navigation 상태 등의 영향으로 일반 안내 helper가
    // 취소 TTS를 건너뛸 수 있다.
    String cancelAnnouncement;
    if (wasNavigation && wasObjectSearch) {
      cancelAnnouncement = '길안내와 물건 찾기를 모두 종료했습니다.';
    } else if (wasNavigation) {
      cancelAnnouncement = '길안내를 종료했습니다.';
    } else if (wasObjectSearch) {
      cancelAnnouncement = '물건 찾기를 종료했습니다.';
    } else {
      cancelAnnouncement = '음성 명령을 취소했습니다.';
    }

    // 직전에 재생 중이던 안내가 남아 있지 않도록 한 번 더 정지한 뒤
    // 취소 완료 문구를 직접 읽는다.
    try {
      await _ttsService.stop();
    } catch (error) {
      print('취소 완료 TTS 전 stop 오류: $error');
    }

    // Android TTS가 stop 직후 바로 speak를 무시하는 단말이 있어
    // 짧은 지연을 둔다.
    await Future<void>.delayed(const Duration(milliseconds: 250));

    if (!mounted) return;

    print('[HARDWARE CANCEL TTS] $cancelAnnouncement');

    try {
      await _ttsService.speak(cancelAnnouncement);
    } catch (error) {
      print('취소 완료 TTS 출력 오류: $error');
    }
  }


  Future<void> _handleVoiceButton() async {
    if (_isAnalyzing || _isFindingRoute) return;

    if (!_speechAvailable) {
      _showMessage('이 기기에서 음성 인식을 사용할 수 없습니다.');
      return;
    }

    if (_isListening) {
      await _stopListening();
    } else {
      await _startListening();
    }
  }

  Future<void> _startListening({bool isRetry = false}) async {
    if (!isRetry) _voiceRetryCount = 0;
    _emptyRecognitionHandled = false;
    setState(() {
      _isListening = true;
      _autoAnalyzeStarted = false;
      _recognizedText = '';
      _statusTitle = '음성 인식 중';
      _statusSubtitle = '말씀하신 내용을 듣고 있습니다.';
    });

    await _speech.listen(
      localeId: 'ko_KR',
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 3),
      partialResults: true,
      onResult: (result) {
        if (!mounted) return;

        setState(() {
          _recognizedText = result.recognizedWords;
        });
      },
    );
  }

  Future<void> _stopListening() async {
    await _speech.stop();

    if (!mounted) return;

    setState(() {
      _isListening = false;
      _statusTitle = '음성 인식 종료';
      _statusSubtitle = '인식된 내용을 확인해주세요.';
    });

    if (_recognizedText.trim().isNotEmpty && !_autoAnalyzeStarted) {
      _autoAnalyzeStarted = true;
      await _analyzeIntent();
    }
  }

  Future<void> _analyzeIntent() async {
    if (_isAnalyzing) return;

    final int commandEpoch = ++_commandEpoch;

    if (_isListening) {
      await _speech.stop();

      if (!mounted) return;

      setState(() {
        _isListening = false;
      });
    }

    final String text = _recognizedText.trim();

    if (text.isEmpty) {
      setState(() {
        _statusTitle = '분석할 문장 없음';
        _statusSubtitle = '먼저 음성을 인식해주세요.';
      });

      _showMessage('인식된 음성이 없습니다.');
      return;
    }

    // "집을 삭제할까요?"에 대한 대답이면 다른 명령보다 먼저 처리한다.
    final SavedPlace? pendingDelete = _takePendingDeletePlace();
    if (pendingDelete != null) {
      final bool handled = await _answerPendingDelete(pendingDelete, text);
      if (handled) return;
      // 네/아니오가 아닌 다른 명령이면 삭제는 취소하고 그 명령을 계속 처리한다.
    }

    // ── 규칙 고속 경로 ──────────────────────────────────────────────
    // "그만", "다시 말해줘", "지금 어디야", "집 삭제해줘"처럼 짧고 뜻이 분명한 말은
    // GPT 응답(2~3초)을 기다리지 않고 바로 처리한다. 긴 문장은 전부 GPT가 판단한다.
    // (예전에는 길이와 상관없이 키워드가 들어가기만 하면 규칙이 GPT를 가로챘다.)
    if (_isShortUtterance(text)) {
      if (_isNavigationCancelCommand(text)) {
        await _cancelNavigationByVoice();
        return;
      }
      if (_isStopWordsOnly(text)) {
        await _handleStopIntent();
        return;
      }
      if (_isObjectFoundReport(text)) {
        // "물병 찾았어"는 물건 찾기 요청이 아니라 완료 보고다.
        await _handleStopIntent(foundByUser: true);
        return;
      }
      if (_isDisconnectCommand(text)) {
        await _handleDisconnectCommand();
        return;
      }
      if (_isConnectCommand(text)) {
        await _handleConnectCommand();
        return;
      }
      if (_isRepeatCommand(text)) {
        await _repeatLastAnnouncement();
        return;
      }
      if (_isWhereAmICommand(text)) {
        await _announceCurrentLocation(commandEpoch: commandEpoch);
        return;
      }
      if (_isDeletePlaceCommand(text)) {
        await _handleDeletePlaceCommand(text);
        return;
      }
    }

    setState(() {
      _isAnalyzing = true;
      _statusTitle = 'GPT 의도 분석 중';
      _statusSubtitle = '사용자 명령의 목적을 분석하고 있습니다.';
    });

    final IntentAnalysisResult result = await _requestIntentAnalysis(text);

    if (!mounted || commandEpoch != _commandEpoch) {
      print('[COMMAND] stale intent result ignored');
      return;
    }

    setState(() {
      _analysisResult = result;
      _isAnalyzing = false;
      _statusTitle = '분석 완료';
      _statusSubtitle = '분석 결과에 따라 다음 동작을 실행합니다.';
    });

    // ── GPT 결과에 따라 분기 ───────────────────────────────────────
    // 여기서부터는 GPT가 돌려준 intent만 본다. 키워드로 GPT 판단을 덮어쓰지 않는다.

    // GPT를 호출하지 못한 경우(네트워크/키 문제): 지팡이와는 BLE로 연결돼 있으므로
    // 한국어 별칭 사전으로 물건 찾기만이라도 처리하고, 아니면 오류를 말한다.
    if (!IntentAnalysisResult.isKnownIntent(result.intent)) {
      await _handleIntentAnalysisFailure(result, text, commandEpoch: commandEpoch);
      return;
    }

    if (result.intent == 'delete_place') {
      await _handleDeletePlaceCommand(text, placeName: result.placeName);
      return;
    }

    if (result.intent == 'stop') {
      await _handleStopIntent();
      return;
    }

    if (result.intent == 'repeat') {
      await _repeatLastAnnouncement();
      return;
    }

    if (result.intent == 'where_am_i') {
      await _announceCurrentLocation(commandEpoch: commandEpoch);
      return;
    }

    if (result.intent == 'status') {
      await _announceSmartCaneStatus(commandEpoch: commandEpoch);
      return;
    }

    if (result.intent == 'connect') {
      await _handleConnectCommand();
      return;
    }

    if (result.intent == 'disconnect') {
      await _handleDisconnectCommand();
      return;
    }

    // GPT가 "물병 찾았어"(완료 보고)를 find_object로 잘못 읽어도 새 찾기를 시작하지 않는다.
    if (result.intent == 'find_object' && _isObjectFoundReport(text)) {
      print('[INTENT] find_object overridden -> stop (found report)');
      await _handleStopIntent(foundByUser: true);
      return;
    }

    if (result.intent == 'find_object') {
      // 객체 찾기 명령에서만 Raspberry Pi의 YOLO 클래스 목록이 필요하다.
      if (_isBleConnected && _yoloClasses.isEmpty) {
        await _requestYoloClasses();

        if (!mounted || commandEpoch != _commandEpoch) {
          print('[COMMAND] stale object search ignored after YOLO class wait');
          return;
        }
      }

      if (_yoloClasses.isEmpty) {
        setState(() {
          _statusTitle = 'YOLO 객체 목록 없음';
          _statusSubtitle = 'SmartCane을 연결한 뒤 다시 시도해주세요.';
        });
        await _speakLowerPriorityAnnouncement(
          '지팡이의 객체 목록을 확인할 수 없습니다. 연결 상태를 확인해주세요.',
        );
        return;
      }

      final String? supportedTarget = _resolveYoloTarget(result, text);
      if (supportedTarget == null) {
        await _stopObjectSearchSilently(clearDisplay: true);
        if (!mounted || commandEpoch != _commandEpoch) return;

        setState(() {
          _statusTitle = '지원하지 않는 물건';
          _statusSubtitle = result.targetLabel.isEmpty
              ? '현재 YOLO 모델에서 찾을 수 없는 물건입니다.'
              : '${result.targetLabel}은 현재 YOLO 모델에서 찾을 수 없습니다.';
        });
        // 찾던 물건을 다른(지원하지 않는) 물건으로 바꾸려다 실패하면
        // 물건 찾기가 끝난 것이므로 멈춰 둔 길안내를 이어간다.
        // "찾을 수 없는 물건입니다. ○○까지 길안내를 이어서 시작합니다"를 한 문장으로 읽는다.
        if (_isNavigationPaused) {
          await _resumeNavigationAfterObjectSearch(
            leadText: '$_statusSubtitle 찾던 물건이 없으므로',
          );
          return;
        }
        await _speakLowerPriorityAnnouncement(_statusSubtitle);
        return;
      }

      // 길안내 중이면 경로를 유지한 채 안내만 잠시 멈추고 물건 찾기로 넘어간다.
      if (_isNavigationGuidanceActive) {
        await _pauseNavigationForObjectSearch(
          result.targetLabel.trim().isEmpty
              ? supportedTarget
              : result.targetLabel.trim(),
        );
        if (!mounted || commandEpoch != _commandEpoch) return;
      }

      await _sendObjectSearchByBle(
        supportedTarget,
        result.targetLabel,
        commandEpoch: commandEpoch,
      );
      return;
    }

    if (result.intent == 'save_place') {
      await _handleSavePlaceCommand(result, text, commandEpoch: commandEpoch);
      return;
    }

    if (result.intent == 'navigate') {
      // "집으로 안내해줘"처럼 저장된 장소 이름이면 검색 없이 저장 좌표로 바로 안내한다.
      final SavedPlace? savedPlace = _matchSavedPlace(result.destination, text);
      await _findRouteWithKakao(
        commandEpoch: commandEpoch,
        savedPlace: savedPlace,
        destination: result.destination,
      );
      return;
    }

    if (!mounted) return;

    setState(() {
      _statusTitle = '명령을 이해하지 못함';
      _statusSubtitle = '물건 찾기, 길안내, 상태 확인, 장소 저장 중 하나로 말씀해 주세요.';
    });
    await _handleUnknownCommand();
  }

  /// 공백을 뺀 길이가 8자 이하인 짧은 발화인지. 규칙 고속 경로는 이런 말에만 쓴다.
  bool _isShortUtterance(String rawText) =>
      _normalizePlaceKey(rawText).length <= 8;

  /// "그만", "멈춰", "중지", "취소"가 들어간 짧은 말. ("저장"이 있으면 장소 삭제 쪽)
  bool _isStopWordsOnly(String rawText) {
    final String t = _normalizePlaceKey(rawText);
    if (t.contains('저장')) return false;
    return t.contains('그만') ||
        t.contains('멈춰') ||
        t.contains('중지') ||
        t.contains('취소') ||
        t.contains('정지');
  }

  /// "물병 찾았어", "다 찾았어", "찾기 끝"처럼 물건을 찾았다고 알리는 완료 보고.
  /// "찾아줘"(요청)와 "못 찾았어"(실패)는 제외한다.
  bool _isObjectFoundReport(String rawText) {
    final String t = _normalizePlaceKey(rawText);
    if (t.contains('저장') || t.contains('못')) return false;
    return t.contains('찾았') ||
        t.contains('찾음') ||
        t.contains('찾기끝') ||
        t.contains('찾기완료');
  }

  /// "지팡이 연결해줘", "다시 연결" 같은 연결 요청. ("해제/끊어"가 있으면 연결 해제 쪽)
  bool _isConnectCommand(String rawText) {
    final String t = _normalizePlaceKey(rawText);
    if (!t.contains('연결')) return false;
    if (t.contains('저장')) return false;
    if (t.contains('해제') || t.contains('끊')) return false;
    return true;
  }

  /// "지팡이 연결 해제", "연결 끊어줘" 같은 연결 해제 요청.
  bool _isDisconnectCommand(String rawText) {
    final String t = _normalizePlaceKey(rawText);
    return t.contains('연결') && (t.contains('해제') || t.contains('끊'));
  }

  /// 음성으로 지팡이 연결. 설정 탭의 검색+연결 버튼과 같은 일을 한다.
  Future<void> _handleConnectCommand() async {
    if (_isBleConnected) {
      if (mounted) {
        setState(() {
          _statusTitle = '지팡이 연결됨';
          _statusSubtitle = '지팡이가 이미 연결되어 있습니다.';
        });
      }
      await _speakInfoAnnouncement('지팡이가 이미 연결되어 있습니다.');
      return;
    }

    if (_isBleScanning || _isAutoReconnecting) {
      await _ttsService.speak('지팡이를 연결하는 중입니다. 잠시만 기다려 주세요.');
      return;
    }

    // 사용자가 직접 끊었던 상태를 풀어 이후 자동 재연결도 다시 동작하게 한다.
    _userDisconnected = false;
    _recordAppLog('connection', '음성 명령으로 지팡이 연결 시도');

    if (mounted) {
      setState(() {
        _selectedTabIndex = 0;
        _statusTitle = '지팡이 연결 중';
        _statusSubtitle = '지팡이를 찾아 연결하고 있습니다.';
      });
    }
    await _ttsService.speak('지팡이를 찾고 있습니다.');

    // 못 찾으면 "지팡이를 찾지 못했습니다…", 연결되면 "지팡이가 연결되었습니다"를 안에서 말한다.
    await _autoConnectSmartCane(announce: true, speakConnected: true);
    if (!mounted) return;

    if (!_isBleConnected && _bleDevice != null) {
      // 찾긴 했지만 연결 단계에서 실패한 경우 (연결 함수는 화면 알림만 띄운다)
      await _ttsService.speak(
        '지팡이를 찾았지만 연결하지 못했습니다. 지팡이 전원을 확인한 뒤 다시 말씀해 주세요.',
      );
    }
  }

  /// 음성으로 지팡이 연결 해제. 직접 끊은 것이므로 자동 재연결하지 않는다.
  Future<void> _handleDisconnectCommand() async {
    if (!_isBleConnected) {
      await _speakInfoAnnouncement('지팡이가 연결되어 있지 않습니다.');
      return;
    }
    await _stopObjectSearchSilently(clearDisplay: true);
    _recordAppLog('connection', '음성 명령으로 지팡이 연결 해제');
    await _disconnectSmartCane();
  }

  /// 중지 의도: 물건 찾기 때문에 길안내가 멈춰 있으면 물건 찾기를 끝내고 길안내를 재개한다.
  /// 길안내 중이면 길안내를 끝내고, 물건 찾기 중이면 지팡이에 STOP을 보낸다.
  /// [foundByUser]면 "물병 찾았어"처럼 사용자가 찾았다고 알린 경우라 안내 문구가 달라진다.
  Future<void> _handleStopIntent({bool foundByUser = false}) async {
    if (_isNavigationPaused) {
      final String label = _currentObjectLabel();
      await _finishObjectSearchAndResumeNavigation(
        leadText: foundByUser && label.isNotEmpty ? '$label을 찾았습니다.' : null,
      );
      return;
    }

    final bool navigationContext = _isNavigating || _isFindingRoute;
    if (navigationContext) {
      if (_activeObjectTarget.trim().isNotEmpty) {
        await _stopObjectSearchSilently(clearDisplay: true);
      }
      await _cancelNavigationByVoice();
      return;
    }
    await _sendStopCommandByBle(foundByUser: foundByUser);
  }

  /// 지금 찾고 있는 물건의 한국어 이름. 없으면 빈 문자열.
  String _currentObjectLabel() {
    final String label = _activeObjectLabel.trim();
    if (label.isNotEmpty) return label;
    return _activeObjectTarget.trim();
  }

  /// GPT 호출 실패 시 처리. 별칭 사전으로 물건 찾기가 되면 그대로 진행하고,
  /// 중지어가 있으면 중지, 그 밖에는 오류를 알린다.
  Future<void> _handleIntentAnalysisFailure(
    IntentAnalysisResult result,
    String rawText, {
    required int commandEpoch,
  }) async {
    print('[INTENT] analysis failed: ${result.intent} / ${result.coreContent}');

    if (_isStopWordsOnly(rawText)) {
      await _handleStopIntent();
      return;
    }
    if (_isObjectFoundReport(rawText)) {
      await _handleStopIntent(foundByUser: true);
      return;
    }
    if (_isDisconnectCommand(rawText)) {
      await _handleDisconnectCommand();
      return;
    }
    if (_isConnectCommand(rawText)) {
      await _handleConnectCommand();
      return;
    }

    if (_isBleConnected && _yoloClasses.isEmpty) {
      await _requestYoloClasses();
      if (!mounted || commandEpoch != _commandEpoch) return;
    }
    final String? offlineTarget =
        _yoloClasses.isEmpty ? null : _resolveYoloTarget(result, rawText);
    if (offlineTarget != null) {
      print('[INTENT] offline alias fallback -> $offlineTarget');
      await _sendObjectSearchByBle(
        offlineTarget,
        _koreanLabelForYoloClass(offlineTarget, rawText),
        commandEpoch: commandEpoch,
      );
      return;
    }

    if (!mounted) return;
    setState(() {
      _statusTitle = '명령 분석 실패';
      _statusSubtitle = result.coreContent;
    });
    await _speakLowerPriorityAnnouncement(
      '명령을 분석하는 서버에 연결하지 못했습니다. 네트워크를 확인한 뒤 다시 말씀해 주세요.',
    );
  }

  /// 별칭 사전으로 찾은 YOLO 클래스에 대해 음성 원문에 들어 있는 한국어 이름을 돌려준다.
  String _koreanLabelForYoloClass(String yoloClass, String rawText) {
    final String haystack = rawText.replaceAll(RegExp(r'\s+'), '');
    for (final MapEntry<String, String> entry in _koreanYoloAliases.entries) {
      if (entry.value == yoloClass && haystack.contains(entry.key)) {
        return entry.key;
      }
    }
    return yoloClass;
  }

  bool _isNavigationCancelCommand(String rawText) {
    final String text = rawText.replaceAll(' ', '').toLowerCase();
    final bool isNavigationContext =
        _isNavigating || _isFindingRoute || _selectedTabIndex == 1;

    if (!isNavigationContext) return false;
    // "집 저장 취소해"는 길안내 취소가 아니라 저장 장소 삭제다.
    if (text.contains('저장')) return false;
    // 물건 찾기 때문에 길안내가 멈춰 있을 때 "그만"은 물건 찾기 종료(→ 길안내 재개)다.
    // "길안내 취소"처럼 길안내를 직접 말했을 때만 길안내 자체를 끝낸다.
    if (_isNavigationPaused &&
        !text.contains('안내') &&
        !text.contains('길찾기')) {
      return false;
    }

    const List<String> cancelExpressions = [
      '취소',
      '중지',
      '멈춰',
      '멈춰줘',
      '그만',
      '그만해',
      '안내종료',
      '길안내종료',
      '길찾기종료',
      '안내취소',
      '길안내취소',
      '길찾기취소',
    ];

    return cancelExpressions.any(text.contains);
  }

  Future<void> _cancelNavigationByVoice() async {
    if (_isListening) {
      await _speech.stop();
    }

    await _stopNavigation(resetGuide: true);
    await _clearRouteOnKakaoMap();

    if (!mounted) return;

    setState(() {
      _selectedTabIndex = 0;
      _recognizedText = '';
      _analysisResult = IntentAnalysisResult.empty();
      _isListening = false;
      _isFindingRoute = false;
      _isAnalyzing = false;
      _autoAnalyzeStarted = false;
      _routeDestinationName = '-';
      _routeSummary = '-';
      _routeFirstGuide = '-';
      _statusTitle = '길안내 취소 완료';
      _statusSubtitle = '홈으로 돌아왔습니다. 새로운 명령을 말씀해주세요.';
    });

    await _speakLowerPriorityAnnouncement(
      '길안내를 취소했습니다. 홈 화면으로 돌아왔습니다.',
      holdDuringHazard: true,
    );
  }

  /// GPT에 알려 줄 현재 앱 상태. "됐어", "고마워"처럼 맥락이 있어야 뜻이 정해지는 말을
  /// 올바로 판단하게 하기 위해 프롬프트에 넣는다.
  String _describeAppStateForIntent() {
    final List<String> parts = <String>[];
    if (_activeObjectTarget.trim().isNotEmpty) {
      parts.add('물건 찾기 중 (찾는 물건: ${_currentObjectLabel()})');
    }
    if (_isNavigationPaused) {
      parts.add('길안내 잠시 멈춤 (목적지: $_routeDestinationName, 물건 찾기가 끝나면 재개)');
    } else if (_isNavigating) {
      parts.add('길안내 중 (목적지: $_routeDestinationName)');
    } else if (_isFindingRoute) {
      parts.add('경로 검색 중');
    }
    if (parts.isEmpty) parts.add('대기 중');
    parts.add(_isBleConnected ? '지팡이 연결됨' : '지팡이 연결 안 됨');
    return parts.join(', ');
  }

  Future<IntentAnalysisResult> _requestIntentAnalysis(String userText) async {
    if (_openAiApiKey.trim().isEmpty ||
        _openAiApiKey.contains('여기에')) {
      return IntentAnalysisResult.error(
        intent: 'error',
        coreContent: 'OpenAI API Key가 설정되지 않았습니다.',
        appAction: 'secrets.json의 OPENAI_API_KEY 값을 설정하세요.',
      );
    }

    try {
      final Uri url = Uri.parse('https://api.openai.com/v1/responses');

      final String supportedClassesJson = jsonEncode(_yoloClasses);
      final String savedPlaceNamesJson = jsonEncode(
        _savedPlaces.map((SavedPlace place) => place.name).toList(),
      );
      final String appStateText = _describeAppStateForIntent();
      final String prompt = '''
시각장애인용 SmartCane 앱의 한국어 음성 명령을 분석하세요.

intent는 다음 중 하나입니다.
- find_object: 사용자가 물건이나 사람을 찾아달라고 요청함 (예: "물병 찾아줘", "내 휴대폰 어디 있어")
- navigate: 특정 장소나 주변 시설로 길안내를 요청함 (예: "근처 편의점으로 안내해줘", "가까운 약국 찾아줘")
- stop: 진행 중인 물건 찾기 또는 길안내를 중지·취소함 (예: "그만해", "길안내 취소", "찾는 거 멈춰줘").
  물건을 이미 찾았다는 완료 보고도 stop입니다 (예: "물병 찾았어", "다 찾았어", "컵 찾았으니까 이제 됐어")
- status: 배터리나 장치 상태를 물어봄
- where_am_i: 현재 위치가 어디인지 물어봄 (예: "지금 어디야", "여기가 어디지", "현재 위치 알려줘")
- repeat: 방금 들은 안내를 다시 말해달라고 함 (예: "다시 말해줘", "뭐라고 했어", "한 번 더 알려줘")
- save_place: 현재 위치나 특정 장소에 이름을 붙여 저장해달라고 요청함 (예: "여기를 집으로 저장해줘", "이 위치를 회사로 기억해", "스타벅스 강남점을 회사로 저장해")
- delete_place: 저장된 장소를 삭제해달라고 요청함 (예: "저장된 집 삭제해줘", "회사 지워줘", "집 저장 취소해")
- connect: 지팡이(SmartCane)를 블루투스로 연결해달라고 함 (예: "지팡이 연결해줘", "지팡이 다시 연결", "스마트케인 연결")
- disconnect: 지팡이 연결을 끊어달라고 함 (예: "지팡이 연결 해제", "지팡이 연결 끊어줘")
- unknown: 그 밖의 명령 또는 의미가 불명확함

현재 라즈베리파이에 로드된 YOLO 모델의 클래스 목록:
$supportedClassesJson

앱에 저장된 장소 이름 목록 (길안내 목적지로 바로 쓸 수 있음):
$savedPlaceNamesJson

앱의 현재 상태:
$appStateText

규칙:
1. find_object이면 사용자가 찾는 물건을 위 목록의 YOLO 영어 클래스 하나로 변환해 target에 넣으세요.
   "찾아줘/어디 있어"(요청)만 find_object입니다. "찾았어/찾았다/찾았습니다"(과거형 완료 보고)는 stop이며 target은 빈 문자열입니다.
2. target은 위 목록에 있는 문자열을 철자와 띄어쓰기까지 그대로 사용해야 합니다.
3. 한국어 이름과 영어 클래스는 의미가 같으면 반드시 매핑하세요. 예시:
   물병/병 → bottle, 휴대폰/핸드폰/폰 → cell phone, 리모컨 → remote, 노트북 → laptop,
   컵 → cup, 의자 → chair, 소파 → couch, 시계 → clock, 칫솔 → toothbrush,
   냉장고 → refrigerator, 가방/배낭 → backpack, 강아지/개 → dog, 사람 → person
4. 목록에 의미가 대응하는 클래스가 정말 없을 때만 target을 빈 문자열로 두세요. 예시: 지갑, 열쇠, 안경 → ""
5. 단순히 비슷하다는 이유로 다른 종류의 물건 클래스를 선택하지 마세요. (지갑을 handbag으로 바꾸지 마세요)
6. targetLabel에는 사용자가 찾으려는 물건의 자연스러운 한국어 이름을 넣으세요. find_object가 아니면 빈 문자열입니다.
7. navigate이면 destination에 지도 검색어를 넣으세요. navigate가 아니면 빈 문자열입니다.
   검색어에는 장소 이름이나 종류만 남기고, "근처/가까운/주변"과 조사(으로/까지/에), "안내해줘/가자" 같은 말은 빼세요.
   예: "근처 편의점으로 안내해줘" → "편의점", "서울역까지 길 안내해줘" → "서울역",
   "버스정류장으로 가고 싶어" → "버스정류장", "가까운 지하철역으로 가자" → "지하철역",
   "서원대학교 정문으로 데려다줘" → "서원대학교 정문"
   사용자가 저장된 장소 이름(집, 회사 등)으로 가자고 하면 destination에 그 저장 이름을 그대로 넣으세요.
   예: "우리집 가자" → "집", "회사로 안내해줘" → "회사", "집에 데려다줘" → "집"
8. save_place이면 placeName에 저장할 이름(집, 회사, 학교 등 짧은 한국어 이름)을 넣으세요.
   "여기", "현재 위치", "이 위치"를 저장하는 경우 destination은 빈 문자열입니다.
   특정 장소를 검색해서 저장하는 경우에만 destination에 그 장소 검색어를 넣으세요.
   delete_place이면 placeName에 삭제할 저장 이름(위 저장된 장소 목록 중 하나)을 넣으세요.
   placeName은 save_place나 delete_place가 아니면 빈 문자열입니다.
9. coreContent는 항상 채우세요. 사용자가 원하는 것을 한국어 한 문장으로 요약합니다. (예: "물병의 위치를 찾고 싶어 함")
10. appAction도 항상 채우세요. intent별로 다음 문구를 사용합니다.
   find_object → "객체 탐색 시작", navigate → "길 안내 화면으로 연결", save_place → "장소 저장", delete_place → "장소 삭제",
   stop → "진행 중인 기능 중지", status → "지팡이 상태 안내", where_am_i → "현재 위치 안내",
   repeat → "마지막 안내 반복", connect → "지팡이 연결", disconnect → "지팡이 연결 해제", unknown → "다시 말하기 요청"
11. JSON 앞뒤에 설명, 인사말, 마크다운 코드블록을 절대 추가하지 마세요.
12. 앱의 현재 상태를 보고 맥락으로 판단하세요. "물건 찾기 중"일 때 "됐어", "이제 됐어", "고마워", "충분해", "끝났어"처럼
   일이 끝났다는 뜻의 말은 물건 찾기를 마치라는 stop입니다. 그러나 "길안내 중"(물건 찾기 아님)일 때 이런 말은
   길안내를 끝내라는 뜻이 아니므로 unknown입니다. 길안내는 "그만", "취소", "중지"처럼 분명한 말로만 stop합니다.
   "대기 중"일 때 "고마워", "됐어"는 unknown입니다.

사용자 음성 명령:
$userText
''';

      // OpenAI Responses API + Structured Outputs.
      // gpt-6-luna는 reasoning effort "none"을 지원하므로 추론 토큰 없이
      // 바로 JSON을 반환하게 하여 응답 지연을 최소화한다.
      final http.Response response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_openAiApiKey',
        },
        body: jsonEncode({
          'model': _openAiModel,
          'input': [
            {
              'role': 'user',
              'content': prompt,
            },
          ],
          'reasoning': {
            'effort': 'none',
          },
          // 같은 명령에 같은 결과가 나오도록 샘플링 무작위성을 없앤다.
          'temperature': 0,
          'max_output_tokens': 200,
          'text': {
            'format': {
              'type': 'json_schema',
              'name': 'smartcane_intent',
              'strict': true,
              'schema': {
                'type': 'object',
                'properties': {
                  'intent': {
                    'type': 'string',
                    'enum': [
                      'find_object',
                      'navigate',
                      'stop',
                      'status',
                      'where_am_i',
                      'repeat',
                      'save_place',
                      'delete_place',
                      'connect',
                      'disconnect',
                      'unknown',
                    ],
                  },
                  'target': {'type': 'string'},
                  'targetLabel': {'type': 'string'},
                  'destination': {'type': 'string'},
                  'placeName': {'type': 'string'},
                  'coreContent': {'type': 'string'},
                  'appAction': {'type': 'string'},
                },
                'required': [
                  'intent',
                  'target',
                  'targetLabel',
                  'destination',
                  'placeName',
                  'coreContent',
                  'appAction',
                ],
                'additionalProperties': false,
              },
            },
          },
        }),
      );

      print('OpenAI 상태 코드: ${response.statusCode}');
      print('OpenAI 응답 내용: ${response.body}');

      if (response.statusCode != 200) {
        return IntentAnalysisResult.error(
          intent: 'API 요청 실패',
          coreContent: '상태 코드: ${response.statusCode}\n${response.body}',
          appAction: 'API Key, 모델명, 네트워크를 확인하세요.',
        );
      }

      final Map<String, dynamic> data = jsonDecode(response.body);

      if (data['status'] == 'incomplete') {
        final dynamic reason = data['incomplete_details']?['reason'];
        return IntentAnalysisResult.error(
          intent: '응답 불완전',
          coreContent: 'OpenAI 응답이 완료되지 않았습니다. ($reason)',
          appAction: '다시 분석을 시도하세요.',
        );
      }

      final String resultText = _extractOpenAiOutputText(data);

      if (resultText.trim().isEmpty) {
        return IntentAnalysisResult.error(
          intent: '분석 실패',
          coreContent: 'OpenAI가 빈 응답을 반환했습니다.',
          appAction: '다시 분석을 시도하세요.',
        );
      }

      final Map<String, dynamic> resultJson =
          _decodeIntentJsonObject(resultText);
      return IntentAnalysisResult.fromJson(resultJson);
    } on FormatException catch (e) {
      return IntentAnalysisResult.error(
        intent: 'error',
        coreContent: e.toString(),
        appAction: 'OpenAI 응답에서 JSON 객체를 읽을 수 없습니다.',
      );
    } catch (e) {
      return IntentAnalysisResult.error(
        intent: 'error',
        coreContent: e.toString(),
        appAction: '네트워크 또는 API Key를 확인하세요.',
      );
    }
  }

  /// Responses API의 output 배열에서 message > output_text 조각을 모아 돌려준다.
  String _extractOpenAiOutputText(Map<String, dynamic> data) {
    final dynamic output = data['output'];
    if (output is! List) return '';

    final StringBuffer buffer = StringBuffer();
    for (final dynamic item in output) {
      if (item is! Map) continue;
      if (item['type'] != 'message') continue;

      final dynamic content = item['content'];
      if (content is! List) continue;

      for (final dynamic part in content) {
        if (part is Map && part['type'] == 'output_text') {
          buffer.write(part['text']?.toString() ?? '');
        }
      }
    }
    return buffer.toString();
  }

  Map<String, dynamic> _decodeIntentJsonObject(String rawText) {
    final String text = rawText.trim();
    if (text.isEmpty) {
      throw const FormatException('OpenAI 응답이 비어 있습니다.');
    }

    final int objectStart = text.indexOf('{');
    final int objectEnd = text.lastIndexOf('}');
    if (objectStart < 0 || objectEnd <= objectStart) {
      throw FormatException(
        'OpenAI 응답에서 JSON 객체를 찾을 수 없습니다: $text',
      );
    }

    final dynamic decoded = jsonDecode(
      text.substring(objectStart, objectEnd + 1),
    );
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('OpenAI JSON 응답이 객체 형식이 아닙니다.');
    }

    return decoded;
  }

  // =====================================================================
  // 시각장애인 사용 편의: 앱 옵션, 자동 연결, 시작 안내, 되묻기, 배터리, 위치/반복
  // =====================================================================

  Future<void> _loadAppOptions() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final bool autoConnect = prefs.getBool(_prefAutoConnect) ?? true;
      final bool simpleMode = prefs.getBool(_prefSimpleMode) ?? false;
      final bool largeText = prefs.getBool(_prefLargeText) ?? false;
      if (!mounted) return;
      setState(() {
        _autoConnectEnabled = autoConnect;
        _simpleModeEnabled = simpleMode;
        _largeTextEnabled = largeText;
      });
      print('[APP OPTION] autoConnect=$autoConnect simpleMode=$simpleMode largeText=$largeText');
    } catch (error) {
      print('앱 옵션 불러오기 오류: $error');
    }
  }

  Future<void> _saveAppOptions() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefAutoConnect, _autoConnectEnabled);
      await prefs.setBool(_prefSimpleMode, _simpleModeEnabled);
      await prefs.setBool(_prefLargeText, _largeTextEnabled);
    } catch (error) {
      print('앱 옵션 저장 오류: $error');
    }
  }

  void _setAutoConnectEnabled(bool enabled) {
    setState(() {
      _autoConnectEnabled = enabled;
    });
    unawaited(_saveAppOptions());
    unawaited(
      _ttsService.speak(enabled ? '자동 연결을 켰습니다.' : '자동 연결을 껐습니다.'),
    );
  }

  void _setLargeTextEnabled(bool enabled) {
    setState(() {
      _largeTextEnabled = enabled;
    });
    unawaited(_saveAppOptions());
    unawaited(
      _ttsService.speak(enabled ? '큰 글씨를 켰습니다.' : '큰 글씨를 껐습니다.'),
    );
  }

  void _setSimpleModeEnabled(bool enabled) {
    setState(() {
      _simpleModeEnabled = enabled;
    });
    unawaited(_saveAppOptions());
    unawaited(
      _ttsService.speak(
        enabled ? '간단 모드를 켰습니다. 핵심 화면만 표시합니다.' : '간단 모드를 껐습니다.',
      ),
    );
  }

  /// 앱 시작: 사용법을 음성으로 안내한 뒤 지팡이에 자동 연결한다.
  Future<void> _runStartupSequence() async {
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    if (!mounted || _startupAnnounced) return;
    _startupAnnounced = true;

    // 1) 앱이 켜졌다는 것만 먼저 알린다.
    await _ttsService.speak('스마트케인 앱이 켜졌습니다.');
    if (!mounted) return;

    // 2) 지팡이 연결 과정. 연결 결과는 아래에서 사용법 안내와 한 문장으로 이어 말한다.
    const String usageGuide = '볼륨 올리기 버튼을 길게 누른 뒤 말씀해 주세요.';
    if (_autoConnectEnabled) {
      await _ttsService.speak('지팡이를 찾고 있습니다.');
      await _autoConnectSmartCane(announce: true, speakConnected: false);
      if (!mounted) return;
      // 3) 연결이 끝난 뒤 사용법 안내. (못 찾은 경우의 안내는 _autoConnectSmartCane이 이미 말했다)
      await _ttsService.speak(
        _isBleConnected ? '지팡이가 연결되었습니다. $usageGuide' : usageGuide,
      );
    } else {
      await _ttsService.speak('설정에서 지팡이를 연결해 주세요. $usageGuide');
    }
  }

  /// 검색 → 연결을 한 번에 수행한다. (자동 연결/재연결용)
  Future<void> _autoConnectSmartCane({
    required bool announce,
    bool speakConnected = true,
  }) async {
    if (_isBleConnected || _isBleScanning) return;
    print('[BLE] auto connect start (announce=$announce)');

    await _scanSmartCane();
    if (!mounted) return;

    if (_bleDevice == null) {
      if (announce) {
        await _ttsService.speak(
          '지팡이를 찾지 못했습니다. 지팡이 전원을 확인한 뒤 설정에서 연결해 주세요.',
        );
      }
      return;
    }

    await _connectSmartCane(speakConnected: speakConnected);
  }

  /// 연결이 끊기면 몇 번 다시 연결을 시도하고 결과를 음성으로 알린다.
  Future<void> _scheduleReconnect() async {
    if (_isAutoReconnecting || !_autoConnectEnabled) return;
    _isAutoReconnecting = true;
    _reconnectAttempt = 0;

    try {
      // 끊김 처리에서 TTS를 멈추므로 잠시 뒤에 말한다.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await _ttsService.speak('지팡이 연결이 끊어졌습니다. 다시 연결을 시도합니다.');

      while (mounted &&
          !_isBleConnected &&
          !_userDisconnected &&
          _reconnectAttempt < _maxReconnectAttempts) {
        _reconnectAttempt += 1;
        print('[BLE] auto reconnect attempt $_reconnectAttempt');
        _recordAppLog('connection', '자동 재연결 시도 $_reconnectAttempt회');
        await _autoConnectSmartCane(announce: false);
        if (_isBleConnected) break;
        await Future<void>.delayed(const Duration(seconds: 3));
      }

      if (mounted && !_isBleConnected && !_userDisconnected) {
        await _ttsService.speak(
          '지팡이를 다시 연결하지 못했습니다. 지팡이 전원을 확인한 뒤 설정에서 연결해 주세요.',
        );
      }
    } finally {
      _isAutoReconnecting = false;
    }
  }

  /// 아무 말도 듣지 못했을 때: 한 번 되묻고 자동으로 다시 듣는다.
  Future<void> _handleEmptyRecognition() async {
    if (_emptyRecognitionHandled) return;
    _emptyRecognitionHandled = true;

    if (_voiceRetryCount >= 1) {
      _voiceRetryCount = 0;
      if (_takePendingDeletePlace() != null) {
        setState(() {
          _statusTitle = '삭제 취소';
          _statusSubtitle = '대답을 듣지 못해 삭제하지 않았습니다.';
        });
        await _ttsService.speak('대답을 듣지 못해 삭제하지 않았습니다.');
        return;
      }
      await _ttsService.speak(
        '음성을 듣지 못했습니다. 볼륨 올리기 버튼을 길게 눌러 다시 시도해 주세요.',
      );
      return;
    }

    _voiceRetryCount += 1;
    await _ttsService.speak('잘 듣지 못했습니다. 다시 말씀해 주세요.');
    if (!mounted || _isListening || _isAnalyzing || !_speechAvailable) return;
    await _startListening(isRetry: true);
  }

  /// 의도를 알 수 없을 때: 한 번 되묻고 자동으로 다시 듣는다.
  Future<void> _handleUnknownCommand() async {
    if (_voiceRetryCount >= 1) {
      _voiceRetryCount = 0;
      await _speakLowerPriorityAnnouncement(
        '명령을 이해하지 못했습니다. 예를 들어 물병 찾아줘, 집으로 안내해줘, '
        '배터리 알려줘라고 말할 수 있습니다.',
      );
      return;
    }

    _voiceRetryCount += 1;
    await _ttsService.speak('명령을 이해하지 못했습니다. 다시 말씀해 주세요.');
    if (!mounted || _isListening || _isAnalyzing || !_speechAvailable) return;
    await _startListening(isRetry: true);
  }

  /// 지팡이 배터리 경고를 음성으로 알린다. 같은 단계는 한 번만 말한다.
  Future<void> _maybeAnnounceBattery() async {
    final double? battery = _piBattery;
    if (battery == null) return;

    final String warning = _piWarning.trim().toUpperCase();
    final bool charging = _piCharging.toLowerCase() == 'charging';
    final bool critical = warning.contains('CRITICAL');
    final bool low = warning == 'LOW';
    final int bucket = (battery / 10).floor();
    String? text;

    if (critical && _lastSpokenBatteryWarning != 'CRITICAL') {
      text = '지팡이 배터리가 ${battery.round()}퍼센트로 매우 부족합니다. '
          '곧 꺼질 수 있으니 바로 충전해 주세요.';
      _lastSpokenBatteryWarning = 'CRITICAL';
    } else if (low && _lastSpokenBatteryWarning.isEmpty) {
      text = '지팡이 배터리가 ${battery.round()}퍼센트입니다. 충전이 필요합니다.';
      _lastSpokenBatteryWarning = 'LOW';
    } else if (!charging &&
        battery <= 30 &&
        _lastSpokenBatteryBucket != -1 &&
        bucket < _lastSpokenBatteryBucket) {
      // 30% 아래에서는 10%씩 떨어질 때마다 한 번 더 알린다.
      text = '지팡이 배터리 ${battery.round()}퍼센트입니다.';
    }

    if (charging || battery > 55) {
      // 충전되거나 회복되면 다음 경고를 다시 말할 수 있게 초기화
      _lastSpokenBatteryWarning = '';
    }
    _lastSpokenBatteryBucket = bucket;

    if (text != null) {
      print('[BATTERY TTS] $text');
      _recordAppLog('status', '배터리 경고: $text');
      await _speakLowerPriorityAnnouncement(text);
    }
  }

  bool _isRepeatCommand(String rawText) {
    final String t = rawText.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    return t.contains('다시말해') ||
        t.contains('다시알려') ||
        t.contains('다시들려') ||
        t.contains('한번더') ||
        t.contains('뭐라고');
  }

  bool _isWhereAmICommand(String rawText) {
    final String t = rawText.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    if (t.contains('저장') || t.contains('기억')) return false; // "여기를 집으로 저장"
    return t.contains('지금어디') ||
        t.contains('여기어디') ||
        t.contains('여긴어디') ||
        t.contains('현재위치') ||
        t.contains('내위치') ||
        t.contains('어디쯤');
  }

  /// "집 삭제해줘", "저장된 회사 지워줘"처럼 저장 장소 삭제 요청인지 판단한다.
  bool _isDeletePlaceCommand(String rawText) {
    final String t = _normalizePlaceKey(rawText);
    final bool hasDeleteWord = t.contains('삭제') ||
        t.contains('지워') ||
        t.contains('지우') ||
        t.contains('없애') ||
        t.contains('제거');
    if (!hasDeleteWord) {
      // "집 저장 취소해"도 삭제로 본다. "취소" 단독은 길안내/기능 중지이므로 "저장"이 함께 있을 때만.
      return t.contains('저장') && t.contains('취소');
    }
    if (t.contains('저장')) return true;
    return _matchSavedPlace('', rawText) != null;
  }

  /// 저장된 장소를 음성으로 삭제한다(한 번 되묻고 "네"면 삭제).
  /// [placeName]은 GPT가 돌려준 이름(없으면 원문에서 찾는다).
  Future<void> _handleDeletePlaceCommand(
    String rawText, {
    String placeName = '',
  }) async {
    if (_savedPlaces.isEmpty) {
      setState(() {
        _statusTitle = '저장된 장소 없음';
        _statusSubtitle = '삭제할 저장 장소가 없습니다.';
      });
      await _speakLowerPriorityAnnouncement('저장된 장소가 없습니다.');
      return;
    }

    SavedPlace? place;
    if (placeName.trim().isNotEmpty) {
      place = _matchSavedPlace(placeName, rawText);
    }
    place ??= _matchSavedPlace('', rawText);

    final String names =
        _savedPlaces.map((SavedPlace p) => p.name).join(', ');
    if (place == null) {
      setState(() {
        _statusTitle = '삭제할 장소를 찾지 못함';
        _statusSubtitle = '저장된 장소: $names';
      });
      await _speakLowerPriorityAnnouncement(
        '어떤 장소를 삭제할지 알 수 없습니다. 저장된 장소는 $names입니다. '
        '예를 들어 집 삭제해줘라고 말해 주세요.',
      );
      return;
    }

    // 바로 지우지 않고 한 번 되묻는다. 대답은 _analyzeIntent 맨 앞에서 받는다.
    final SavedPlace target = place;
    _pendingDeletePlace = target;
    _pendingDeleteAskedAt = DateTime.now();
    setState(() {
      _statusTitle = '삭제 확인';
      _statusSubtitle =
          '저장된 위치 ${_withParticle(target.name, '을', '를')} 삭제할까요? "네" 또는 "아니오"로 대답해 주세요.';
    });
    print('[SAVED PLACE] delete confirm asked: ${target.name}');
    await _ttsService.speak(
      '저장된 위치 ${_withParticle(target.name, '을', '를')} 삭제할까요? 네 또는 아니오로 대답해 주세요.',
    );
    if (!mounted || _isListening || _isAnalyzing || !_speechAvailable) return;
    await _startListening(isRetry: true);
  }

  /// 되묻기 중인 장소를 꺼낸다. 60초가 지났으면 없는 것으로 본다.
  SavedPlace? _takePendingDeletePlace() {
    final SavedPlace? place = _pendingDeletePlace;
    final DateTime? askedAt = _pendingDeleteAskedAt;
    _pendingDeletePlace = null;
    _pendingDeleteAskedAt = null;
    if (place == null || askedAt == null) return null;
    if (DateTime.now().difference(askedAt) > _pendingDeleteTimeout) {
      print('[SAVED PLACE] delete confirm expired: ${place.name}');
      return null;
    }
    return place;
  }

  /// 되묻기에 대한 대답 처리. 네 → 삭제, 아니오 → 취소.
  /// 1) "어", "응", "네", "아니"처럼 분명한 짧은 대답은 규칙으로 즉시 판정한다.
  /// 2) 규칙에 없는 말("그래 그거 지워버려", "음… 아니 놔둬")은 GPT에 네/아니오/다른 명령을 묻는다.
  /// 3) 다른 명령이면 삭제를 취소하고 false를 돌려 원래 명령 처리로 넘긴다.
  Future<bool> _answerPendingDelete(SavedPlace place, String rawText) async {
    String verdict = _classifyConfirmationByRule(rawText);

    if (verdict == 'other') {
      setState(() {
        _statusTitle = '대답 확인 중';
        _statusSubtitle = '"$rawText"가 삭제 승낙인지 확인하고 있습니다.';
      });
      final String? byGpt = await _classifyConfirmationWithGpt(
        question: '저장된 위치 ${_withParticle(place.name, '을', '를')} 삭제할까요?',
        answer: rawText,
      );
      print('[SAVED PLACE] confirm by GPT: "$rawText" -> $byGpt');
      // GPT를 못 부르면 지우지 않는 쪽(취소)으로 처리한다.
      verdict = byGpt ?? 'no';
      if (!mounted) return true;
    } else {
      print('[SAVED PLACE] confirm by rule: "$rawText" -> $verdict');
    }

    if (verdict == 'yes') {
      await _finishDeleteSavedPlace(place);
      return true;
    }

    setState(() {
      _statusTitle = '삭제 취소';
      _statusSubtitle =
          '저장된 위치 ${_withParticle(place.name, '을', '를')} 삭제하지 않았습니다.';
    });
    await _speakLowerPriorityAnnouncement('삭제를 취소했습니다.');
    // 'no'면 여기서 끝, 'other'면 원래 명령으로 이어서 처리한다.
    return verdict == 'no';
  }

  /// 규칙으로 판정할 수 있는 분명한 대답만 yes/no, 나머지는 other.
  String _classifyConfirmationByRule(String rawText) {
    // 공백·문장부호 제거
    final String t = rawText
        .replaceAll(RegExp(r'[\s\.,!?~…ㅋㅎ]+'), '')
        .toLowerCase();
    if (t.isEmpty) return 'other';

    // 부정은 들어 있기만 해도 취소 (지우지 않는 쪽이 안전)
    const List<String> noWords = <String>[
      '아니', '아뇨', '아니오', '취소', '싫어', '하지마', '안돼', '안해', '그만', '놔둬', '냅둬', '노',
    ];
    if (noWords.any(t.contains)) return 'no';

    // 분명한 승낙어는 길이와 상관없이
    const List<String> strongYes = <String>['삭제', '지워', '지우', '없애', '제거'];
    if (strongYes.any(t.contains)) return 'yes';

    // 짧은 대답은 통째로 승낙어와 같을 때만 ("어디야"의 "어"로 지워지지 않게)
    const Set<String> exactYes = <String>{
      '어', '어어', '응', '응응', '웅', '엉', '네', '네네', '예', '예예', '넹', '넵', '옙',
      '그래', '그래요', '그렇지', '그럼', '맞아', '맞아요', '맞습니다', '좋아', '좋아요',
      '오케이', 'ok', '오키', '예스', '당연하지', '당연', '해', '해줘', '해주세요', '그렇게해', '그렇게해줘',
    };
    if (exactYes.contains(t)) return 'yes';

    return 'other';
  }

  /// 규칙에 없는 대답을 GPT에 물어 'yes' / 'no' / 'other' 중 하나를 받는다. 실패하면 null.
  Future<String?> _classifyConfirmationWithGpt({
    required String question,
    required String answer,
  }) async {
    if (_openAiApiKey.trim().isEmpty || _openAiApiKey.contains('여기에')) {
      return null;
    }
    final String prompt = '''
시각장애인용 앱이 사용자에게 "$question"라고 물었고, 사용자가 "$answer"라고 대답했습니다.
이 대답을 분류하세요.
- yes: 삭제에 동의함 (예: "어", "응 지워", "그래 그거 없애버려", "맞아 삭제해")
- no: 삭제를 원하지 않음 (예: "아니", "놔둬", "그냥 두자", "취소")
- other: 질문과 상관없는 다른 명령이나 말 (예: "물병 찾아줘", "배터리 알려줘")
''';
    try {
      final http.Response response = await http
          .post(
            Uri.parse('https://api.openai.com/v1/responses'),
            headers: <String, String>{
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $_openAiApiKey',
            },
            body: jsonEncode(<String, dynamic>{
              'model': _openAiModel,
              'input': <Map<String, String>>[
                <String, String>{'role': 'user', 'content': prompt},
              ],
              'reasoning': <String, String>{'effort': 'none'},
              'temperature': 0,
              'max_output_tokens': 50,
              'text': <String, dynamic>{
                'format': <String, dynamic>{
                  'type': 'json_schema',
                  'name': 'smartcane_confirmation',
                  'strict': true,
                  'schema': <String, dynamic>{
                    'type': 'object',
                    'properties': <String, dynamic>{
                      'answer': <String, dynamic>{
                        'type': 'string',
                        'enum': <String>['yes', 'no', 'other'],
                      },
                    },
                    'required': <String>['answer'],
                    'additionalProperties': false,
                  },
                },
              },
            }),
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        print('[CONFIRM GPT] HTTP ${response.statusCode}: ${response.body}');
        return null;
      }
      final Map<String, dynamic> data = jsonDecode(response.body);
      final String text = _extractOpenAiOutputText(data);
      final Map<String, dynamic> json = _decodeIntentJsonObject(text);
      final String verdict = json['answer']?.toString().trim() ?? '';
      return (verdict == 'yes' || verdict == 'no' || verdict == 'other') ? verdict : null;
    } catch (error) {
      print('[CONFIRM GPT] error: $error');
      return null;
    }
  }

  /// 실제 삭제 + 화면/음성 안내. 음성 삭제와 버튼 삭제가 함께 쓴다.
  Future<void> _finishDeleteSavedPlace(SavedPlace place) async {
    await _deleteSavedPlace(place);
    if (!mounted) return;
    final String spoken =
        '저장된 위치 ${_withParticle(place.name, '이', '가')} 삭제되었습니다.';
    setState(() {
      _statusTitle = '장소 삭제 완료';
      _statusSubtitle = spoken;
    });
    _showMessage('${place.name} 삭제됨');
    await _speakLowerPriorityAnnouncement(spoken);
  }

  /// 받침 유무에 따라 조사를 붙인다. 예: ("집", "을", "를") → "집을", ("회사", "이", "가") → "회사가"
  String _withParticle(String word, String withBatchim, String withoutBatchim) {
    final String w = word.trim();
    if (w.isEmpty) return w;
    final int code = w.codeUnitAt(w.length - 1);
    if (code < 0xAC00 || code > 0xD7A3) return '$w$withBatchim';
    final bool hasBatchim = (code - 0xAC00) % 28 != 0;
    return '$w${hasBatchim ? withBatchim : withoutBatchim}';
  }

  /// "다시 말해줘": 길안내 중이면 현재 안내, 아니면 마지막 안내 문장을 반복한다.
  Future<void> _repeatLastAnnouncement() async {
    String text;
    if (_isNavigating && _navigationGuide.trim().isNotEmpty) {
      text = _navigationGuide.trim();
      if (_upcomingNavigationGuide.trim().isNotEmpty) {
        text = '$text ${_upcomingNavigationGuide.trim()}';
      }
    } else if (_lastAnnouncementText.trim().isNotEmpty) {
      text = _lastAnnouncementText.trim();
    } else {
      text = '다시 들려드릴 안내가 없습니다.';
    }

    setState(() {
      _statusTitle = '안내 다시 듣기';
      _statusSubtitle = text;
    });
    print('[REPEAT] $text');
    await _ttsService.speak(text);
  }

  /// "지금 어디야": 현재 위치의 도로명 주소와, 길안내 중이면 목적지까지 남은 거리를 말한다.
  Future<void> _announceCurrentLocation({required int commandEpoch}) async {
    setState(() {
      _statusTitle = '현재 위치 확인 중';
      _statusSubtitle = 'GPS 위치를 주소로 바꾸고 있습니다.';
    });

    try {
      final Position position = await _getCurrentPosition();
      final String address = await _reverseGeocode(
        longitude: position.longitude,
        latitude: position.latitude,
      );
      if (!mounted || commandEpoch != _commandEpoch) return;

      final StringBuffer speech = StringBuffer();
      if (address.isEmpty) {
        speech.write('주소를 확인하지 못했습니다. ');
      } else {
        speech.write('현재 위치는 $address 근처입니다. ');
      }

      final double? destLat = _routeDestinationLatitude;
      final double? destLng = _routeDestinationLongitude;
      if (_isNavigating && destLat != null && destLng != null) {
        final double remaining = Geolocator.distanceBetween(
          position.latitude,
          position.longitude,
          destLat,
          destLng,
        );
        speech.write(
          '목적지 $_routeDestinationName까지 약 ${remaining.round()}미터 남았습니다.',
        );
      }

      final String text = speech.toString().trim();
      setState(() {
        _statusTitle = '현재 위치';
        _statusSubtitle = address.isEmpty
            ? '위도 ${position.latitude.toStringAsFixed(5)}, 경도 ${position.longitude.toStringAsFixed(5)}'
            : address;
      });
      print('[WHERE] $text');
      await _speakInfoAnnouncement(text);
    } catch (error) {
      if (!mounted || commandEpoch != _commandEpoch) return;
      setState(() {
        _statusTitle = '현재 위치 확인 실패';
        _statusSubtitle = error.toString();
      });
      await _speakInfoAnnouncement(
        '현재 위치를 확인하지 못했습니다. 위치 권한과 GPS 상태를 확인해 주세요.',
      );
    }
  }

  /// 길안내나 물건 찾기 중에는 화면이 꺼지지 않게 한다.
  void _updateWakelock() {
    final bool keepAwake =
        _isNavigating || _isFindingRoute || _activeObjectTarget.trim().isNotEmpty;
    if (keepAwake == _wakelockEnabled) return;
    _wakelockEnabled = keepAwake;
    print('[WAKELOCK] ${keepAwake ? 'on' : 'off'}');
    unawaited(WakelockPlus.toggle(enable: keepAwake));
  }

  // =====================================================================
  // 동작 기록 (심사용): 지팡이 통신 + 앱 내부 사건, 쉬운 설명 / 원문 두 가지로 표시
  // =====================================================================

  void _recordBleLog({required bool toPi, required String raw}) {
    final String trimmed = raw.trim();
    if (trimmed.isEmpty) return;

    // 0.5초마다 오는 센서값/상태 패킷은 로그를 덮어 버리므로 제외한다.
    if (!toPi) {
      if (trimmed.contains('"type":"tof"') ||
          trimmed.contains('"type":"status"')) {
        return;
      }
      // 물건 목록 묶음은 첫 조각만 남긴다.
      if (trimmed.contains('"type":"object_classes"') &&
          !trimmed.contains('"index":0,') &&
          !trimmed.contains('"not_ready"')) {
        return;
      }
    }

    _pushLogEntry(
      BleLogEntry(
        at: DateTime.now(),
        toPi: toPi,
        raw: trimmed,
        easy: _describeBleMessage(toPi: toPi, raw: trimmed),
        category: _categorizeBleMessage(toPi: toPi, raw: trimmed),
      ),
    );
  }

  /// 지팡이와 통신하지 않는 앱 내부 사건(장소 저장, 경로 탐색, 상태 안내, 연결)을 로그에 남긴다.
  void _recordAppLog(String category, String text) {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _pushLogEntry(
      BleLogEntry(
        at: DateTime.now(),
        toPi: null,
        raw: trimmed,
        easy: trimmed,
        category: category,
      ),
    );
  }

  void _pushLogEntry(BleLogEntry entry) {
    _bleLog.insert(0, entry);
    if (_bleLog.length > _bleLogMaxEntries) {
      _bleLog.removeRange(_bleLogMaxEntries, _bleLog.length);
    }
    if (mounted) setState(() {});
  }

  String _categorizeBleMessage({required bool toPi, required String raw}) {
    if (toPi) {
      final String upper = raw.toUpperCase();
      if (upper.startsWith('FIND:') || upper == 'STOP' || upper == 'GET_CLASSES') {
        return 'object';
      }
      if (upper.startsWith('NAV:')) return 'navigation';
      if (upper.startsWith('HAZARD:')) return 'hazard';
      if (upper == 'STATUS') return 'status';
      if (upper == 'PING') return 'connection';
      return 'other';
    }

    if (raw == 'HELLO FROM PI' || raw == 'PONG FROM PI') return 'connection';
    if (raw.contains('"type":"object"') ||
        raw.contains('"type":"search"') ||
        raw.contains('"type":"object_classes"')) {
      return 'object';
    }
    if (raw.contains('"type":"hazard"') ||
        raw.contains('"type":"hazard_setting"') ||
        raw.contains('"type":"tof_recovery"')) {
      return 'hazard';
    }
    if (raw.contains('"type":"navigation_motor"')) return 'navigation';
    if (raw.contains('"type":"status"')) return 'status';
    return 'other';
  }

  /// 명령/패킷을 비전공자도 읽을 수 있는 한 줄 설명으로 바꾼다.
  String _describeBleMessage({required bool toPi, required String raw}) {
    if (toPi) {
      final String upper = raw.toUpperCase();
      if (upper.startsWith('FIND:')) {
        final String target = raw.substring(5).trim();
        return '"${_objectDisplayName(target)}" 찾기 시작';
      }
      if (upper == 'STOP') return '물건 찾기 중지';
      if (upper == 'GET_CLASSES') return '찾을 수 있는 물건 목록 요청';
      if (upper == 'STATUS') return '지팡이 상태 요청';
      if (upper == 'PING') return '연결 확인';
      if (upper.startsWith('NAV:')) {
        final String action = upper.substring(4).trim();
        const Map<String, String> labels = <String, String>{
          'FORWARD': '직진 진동',
          'LEFT': '왼쪽 진동',
          'RIGHT': '오른쪽 진동',
          'UTURN': '뒤로 돌기 진동',
          'STOP': '길안내 진동 종료',
        };
        return '길안내: ${labels[action] ?? action}';
      }
      if (upper.startsWith('HAZARD:')) {
        final String arg = upper.substring(7).trim();
        if (arg == 'OFF') return '위험 감지 끄기';
        if (arg == 'ON') return '위험 감지 켜기';
        if (arg == 'GET') return '위험 감지 설정 조회';
        if (arg.startsWith('DIST:')) {
          // DIST:FRONT:120 처럼 방향이 붙으면 그 방향 이름을 앞에 붙인다.
          final List<String> parts = arg.substring(5).split(':');
          final String value = parts.last.trim();
          final String label = parts.length > 1
              ? '${_hazardDirectionLabels[parts.first.trim()] ?? parts.first} '
              : '';
          return value == 'DEFAULT'
              ? '$label위험 감지 거리를 기본 기준으로'
              : '$label위험 감지 거리 ${value}cm 이내로';
        }
      }
      return raw;
    }

    if (raw == 'HELLO FROM PI') return '지팡이가 연결 인사를 보냄';
    if (raw == 'PONG FROM PI') return '지팡이가 연결 확인에 응답';

    Map<String, dynamic>? json;
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) json = decoded;
    } catch (_) {}
    if (json == null) return raw;

    final String type = json['type']?.toString() ?? '';
    switch (type) {
      case 'object':
        final String target = json['target']?.toString() ?? '';
        final String direction = json['direction']?.toString() ?? '';
        final dynamic confidence = json['confidence'];
        final String confidenceText = confidence is num
            ? ' (확신도 ${(confidence * 100).round()}%)'
            : '';
        return '"${_objectDisplayName(target)}" 발견: ${_directionLabel(direction)}$confidenceText';
      case 'hazard':
        if (json['state']?.toString() == 'detected') {
          final List<String> positions = _hazardPositions(json);
          final dynamic distances = json['distances_cm'];
          final List<String> parts = <String>[];
          for (int i = 0; i < positions.length; i++) {
            final dynamic d = distances is List && i < distances.length ? distances[i] : null;
            parts.add(d is num ? '${positions[i]} ${d.round()}cm' : positions[i]);
          }
          return '장애물 감지: ${parts.join(', ')}';
        }
        return '장애물 없음 (위험 해제)';
      case 'search':
        final String state = json['state']?.toString() ?? '';
        final String target = json['target']?.toString() ?? '';
        if (state == 'started') return '지팡이가 "${_objectDisplayName(target)}" 찾기를 시작함';
        if (state == 'stopped') return '지팡이가 물건 찾기를 멈춤';
        if (state == 'rejected') return '지팡이가 "$target"은 찾을 수 없다고 응답';
        return '물건 찾기 상태: $state';
      case 'navigation_motor':
        final String action = json['action']?.toString() ?? '';
        final String state = json['state']?.toString() ?? '';
        return '진동 모터 ${_navigationMotorLabel(action)} · $state';
      case 'hazard_setting':
        final bool enabled = json['enabled'] == true;
        final dynamic thresholds = json['thresholds_cm'];
        return '위험 감지 설정 적용됨: ${enabled ? '켜짐' : '꺼짐'}'
            '${thresholds is Map ? ', ${_formatHazardThresholds(thresholds)} 이내' : ''}';
      case 'object_classes':
        if (json['state']?.toString() == 'not_ready') return '물건 목록 아직 준비 안 됨';
        return '찾을 수 있는 물건 목록 전송 시작 (${json['total']}묶음)';
      case 'tof_recovery':
        return '거리 센서 자동 복구: ${json['state']}';
      case 'error':
        return '지팡이 오류: ${json['message']}';
      default:
        return type.isEmpty ? raw : '$type 패킷';
    }
  }

  Widget _buildBleLogCard() {
    const Color accent = Color(0xFF155EEF);
    const Color muted = Color(0xFF747A84);
    final List<BleLogEntry> entries = _bleLog
        .where((BleLogEntry e) => _bleLogFilter.isEmpty || e.category == _bleLogFilter)
        .take(10)
        .toList();
    final String filterName = kBleLogCategories
        .firstWhere((MapEntry<String, String> c) => c.key == _bleLogFilter)
        .value;

    String timeLabel(DateTime at) =>
        '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}:${at.second.toString().padLeft(2, '0')}';

    return _surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Expanded(
                child: Text(
                  '동작 기록',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF202329),
                  ),
                ),
              ),
              TextButton(
                onPressed: entries.isEmpty
                    ? null
                    : () => setState(() {
                          _bleLog.clear();
                        }),
                child: const Text('지우기', style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            '앱과 지팡이가 주고받은 명령과 앱의 주요 동작입니다. 기능별로 골라 보고, 쉬운 설명과 원문을 바꿔 볼 수 있습니다.',
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              fontWeight: FontWeight.w600,
              color: muted,
            ),
          ),
          const SizedBox(height: 12),
          SegmentedButton<bool>(
            segments: const <ButtonSegment<bool>>[
              ButtonSegment<bool>(
                value: false,
                label: Text('쉬운 설명'),
                icon: Icon(Icons.lightbulb_outline_rounded, size: 18),
              ),
              ButtonSegment<bool>(
                value: true,
                label: Text('원문'),
                icon: Icon(Icons.code_rounded, size: 18),
              ),
            ],
            selected: <bool>{_bleLogShowRaw},
            onSelectionChanged: (Set<bool> selection) => setState(() {
              _bleLogShowRaw = selection.first;
            }),
            style: SegmentedButton.styleFrom(
              selectedBackgroundColor: const Color(0xFFEAF2FF),
              selectedForegroundColor: accent,
            ),
          ),
          const SizedBox(height: 10),
          // 기능별 필터: 선택한 기능의 기록만 표시
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: kBleLogCategories.map((MapEntry<String, String> c) {
                final bool selected = _bleLogFilter == c.key;
                final int count = c.key.isEmpty
                    ? _bleLog.length
                    : _bleLog.where((BleLogEntry e) => e.category == c.key).length;
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(count > 0 && c.key.isNotEmpty ? '${c.value} $count' : c.value),
                    selected: selected,
                    showCheckmark: false,
                    selectedColor: const Color(0xFFEAF2FF),
                    labelStyle: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: selected ? accent : const Color(0xFF555B65),
                    ),
                    side: BorderSide(
                      color: selected ? const Color(0xFFC9D6F2) : const Color(0xFFE2E5EA),
                    ),
                    onSelected: (_) => setState(() {
                      _bleLogFilter = c.key;
                    }),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 10),
          if (entries.isEmpty)
            Text(
              _bleLogFilter.isEmpty
                  ? '아직 기록이 없습니다. 지팡이를 연결하고 음성 명령을 해 보세요.'
                  : '"$filterName" 기록이 아직 없습니다.',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: muted),
            )
          else
            ...entries.map(
              (BleLogEntry entry) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: entry.toPi == null
                            ? const Color(0xFFF3EEFF)
                            : (entry.toPi == true
                                ? const Color(0xFFEAF2FF)
                                : const Color(0xFFECF8F2)),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Icon(
                        entry.toPi == null
                            ? Icons.smartphone_rounded
                            : (entry.toPi == true
                                ? Icons.arrow_upward_rounded
                                : Icons.arrow_downward_rounded),
                        size: 18,
                        color: entry.toPi == null
                            ? const Color(0xFF6E4DBF)
                            : (entry.toPi == true ? accent : const Color(0xFF1D9B62)),
                      ),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            '${timeLabel(entry.at)} · ${entry.toPi == null ? '앱' : (entry.toPi == true ? '앱 → 지팡이' : '지팡이 → 앱')}',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF8A8F98),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _bleLogShowRaw ? entry.raw : entry.easy,
                            maxLines: _bleLogShowRaw ? 3 : 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: _bleLogShowRaw ? 12 : 14,
                              height: 1.35,
                              fontFamily: _bleLogShowRaw ? 'monospace' : null,
                              fontWeight: _bleLogShowRaw ? FontWeight.w500 : FontWeight.w700,
                              color: const Color(0xFF202329),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  // =====================================================================
  // 저장된 장소 (집 / 회사 등)
  // =====================================================================

  Future<void> _loadSavedPlaces() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String raw = prefs.getString(_prefSavedPlaces) ?? '';
      if (raw.trim().isEmpty) return;

      final dynamic decoded = jsonDecode(raw);
      if (decoded is! List) return;

      final List<SavedPlace> loaded = decoded
          .whereType<Map>()
          .map((Map item) => SavedPlace.fromJson(Map<String, dynamic>.from(item)))
          .where((SavedPlace place) => place.name.isNotEmpty)
          .toList();

      if (!mounted) return;
      setState(() {
        _savedPlaces = loaded;
      });
      print('[SAVED PLACE] loaded ${loaded.length}: '
          '${loaded.map((SavedPlace p) => p.name).join(', ')}');
    } catch (error) {
      print('저장된 장소 불러오기 오류: $error');
    }
  }

  Future<void> _persistSavedPlaces() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefSavedPlaces,
        jsonEncode(_savedPlaces.map((SavedPlace p) => p.toJson()).toList()),
      );
    } catch (error) {
      print('저장된 장소 저장 오류: $error');
    }
  }

  String _normalizePlaceKey(String value) =>
      value.replaceAll(RegExp(r'\s+'), '').toLowerCase();

  /// 같은 이름이 있으면 덮어쓰고, 없으면 추가한다.
  Future<void> _upsertSavedPlace(SavedPlace place) async {
    final String key = _normalizePlaceKey(place.name);
    final List<SavedPlace> next = _savedPlaces
        .where((SavedPlace p) => _normalizePlaceKey(p.name) != key)
        .toList()
      ..insert(0, place);

    if (mounted) {
      setState(() {
        _savedPlaces = next;
      });
    } else {
      _savedPlaces = next;
    }
    await _persistSavedPlaces();
    print('[SAVED PLACE] saved ${place.name} '
        '(${place.latitude}, ${place.longitude}) ${place.address}');
    _recordAppLog('place', '장소 저장: ${place.name} · ${place.address}');
  }

  Future<void> _deleteSavedPlace(SavedPlace place) async {
    final String key = _normalizePlaceKey(place.name);
    setState(() {
      _savedPlaces = _savedPlaces
          .where((SavedPlace p) => _normalizePlaceKey(p.name) != key)
          .toList();
    });
    await _persistSavedPlaces();
    print('[SAVED PLACE] deleted ${place.name}');
    _recordAppLog('place', '장소 삭제: ${place.name}');
  }

  /// 저장 이름별 말하기 변형. "우리집 가자", "직장으로 안내" 같은 표현을 받아준다.
  List<String> _savedPlaceAliases(String name) {
    final String key = _normalizePlaceKey(name);
    final List<String> aliases = <String>[key];
    if (key == '집') aliases.addAll(<String>['우리집', '집으로', '집에', '홈']);
    if (key == '회사') aliases.addAll(<String>['직장', '사무실', '회사로']);
    if (key == '학교') aliases.addAll(<String>['학교로', '캠퍼스']);
    return aliases;
  }

  /// GPT가 돌려준 destination 또는 음성 원문에서 저장된 장소를 찾는다.
  /// 긴 이름부터 비교해 "회사 앞 편의점"이 "회사"로 잘못 잡히지 않게 한다.
  SavedPlace? _matchSavedPlace(String destination, String rawText) {
    if (_savedPlaces.isEmpty) return null;

    final String destinationKey = _normalizePlaceKey(destination);
    final String textKey = _normalizePlaceKey(rawText);

    // 1) destination이 저장 이름과 정확히 같으면 최우선
    for (final SavedPlace place in _savedPlaces) {
      if (destinationKey.isNotEmpty &&
          destinationKey == _normalizePlaceKey(place.name)) {
        return place;
      }
    }

    // 2) "근처 편의점"처럼 다른 목적지가 명확하면 저장 장소로 바꾸지 않는다.
    if (destinationKey.isNotEmpty &&
        (destinationKey.contains('근처') || destinationKey.contains('가까운'))) {
      return null;
    }

    final List<SavedPlace> sorted = List<SavedPlace>.from(_savedPlaces)
      ..sort((SavedPlace a, SavedPlace b) => b.name.length.compareTo(a.name.length));

    for (final SavedPlace place in sorted) {
      for (final String alias in _savedPlaceAliases(place.name)) {
        if (alias.isEmpty) continue;
        // GPT가 목적지를 돌려줬으면 그 문자열만 본다. 원문 전체를 보면
        // "집에서 가까운 약국"처럼 다른 목적지가 집으로 잘못 잡힌다.
        final bool matched = destinationKey.isNotEmpty
            ? destinationKey.contains(alias)
            : textKey.contains(alias);
        if (matched) return place;
      }
    }
    return null;
  }

  /// 카카오 좌표→주소 변환. 실패하면 빈 문자열.
  Future<String> _reverseGeocode({
    required double longitude,
    required double latitude,
  }) async {
    if (_kakaoRestApiKey.trim().isEmpty) return '';
    try {
      final Uri url = Uri.https(
        'dapi.kakao.com',
        '/v2/local/geo/coord2address.json',
        <String, String>{
          'x': longitude.toString(),
          'y': latitude.toString(),
          'input_coord': 'WGS84',
        },
      );
      final http.Response response = await http.get(
        url,
        headers: <String, String>{'Authorization': 'KakaoAK $_kakaoRestApiKey'},
      );
      if (response.statusCode != 200) return '';

      final Map<String, dynamic> data = jsonDecode(response.body);
      final dynamic documents = data['documents'];
      if (documents is! List || documents.isEmpty) return '';

      final Map<String, dynamic> first =
          Map<String, dynamic>.from(documents.first as Map);
      final dynamic road = first['road_address'];
      final dynamic lot = first['address'];
      if (road is Map && (road['address_name']?.toString() ?? '').isNotEmpty) {
        return road['address_name'].toString();
      }
      if (lot is Map) return lot['address_name']?.toString() ?? '';
      return '';
    } catch (error) {
      print('주소 변환 오류: $error');
      return '';
    }
  }

  /// 현재 GPS 위치를 [name]으로 저장한다.
  Future<bool> _saveCurrentLocationAs(String name) async {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) return false;
    if (_isSavingPlace) return false;

    setState(() {
      _isSavingPlace = true;
      _statusTitle = '위치 저장 중';
      _statusSubtitle = '현재 위치를 $trimmed(으)로 저장하고 있습니다.';
    });

    try {
      final Position position = await _getCurrentPosition();
      final String address = await _reverseGeocode(
        longitude: position.longitude,
        latitude: position.latitude,
      );
      if (!mounted) return false;

      await _upsertSavedPlace(
        SavedPlace(
          name: trimmed,
          address: address.isEmpty
              ? '위도 ${position.latitude.toStringAsFixed(5)}, '
                  '경도 ${position.longitude.toStringAsFixed(5)}'
              : address,
          longitude: position.longitude,
          latitude: position.latitude,
          savedAt: DateTime.now(),
        ),
      );

      if (!mounted) return true;
      setState(() {
        _isSavingPlace = false;
        _statusTitle = '위치 저장 완료';
        _statusSubtitle = '현재 위치를 $trimmed(으)로 저장했습니다.';
      });
      _showMessage('$trimmed 저장 완료');
      await _speakLowerPriorityAnnouncement(
        '현재 위치를 $trimmed(으)로 저장했습니다. '
        '이제 $trimmed(으)로 안내해 달라고 말하면 바로 안내합니다.',
      );
      return true;
    } catch (error) {
      if (!mounted) return false;
      setState(() {
        _isSavingPlace = false;
        _statusTitle = '위치 저장 실패';
        _statusSubtitle = error.toString();
      });
      _showMessage('위치 저장 실패');
      await _speakLowerPriorityAnnouncement(
        '현재 위치를 저장하지 못했습니다. 위치 권한과 GPS 상태를 확인해주세요.',
      );
      return false;
    }
  }

  /// [keyword]를 카카오에서 검색해 첫 결과를 [name]으로 저장한다.
  Future<bool> _searchAndSavePlace({
    required String name,
    required String keyword,
  }) async {
    final String trimmedName = name.trim();
    final String trimmedKeyword = keyword.trim();
    if (trimmedName.isEmpty || trimmedKeyword.isEmpty) return false;
    if (_isSavingPlace) return false;

    setState(() {
      _isSavingPlace = true;
      _statusTitle = '장소 검색 중';
      _statusSubtitle = '$trimmedKeyword을(를) 찾아 $trimmedName(으)로 저장합니다.';
    });

    try {
      final Position position = await _getCurrentPosition();
      final KakaoPlace place = await _searchKakaoPlace(
        keyword: trimmedKeyword,
        longitude: position.longitude,
        latitude: position.latitude,
      );
      if (!mounted) return false;

      await _upsertSavedPlace(
        SavedPlace(
          name: trimmedName,
          address: place.address.isEmpty ? place.name : '${place.name} · ${place.address}',
          longitude: place.longitude,
          latitude: place.latitude,
          savedAt: DateTime.now(),
        ),
      );

      if (!mounted) return true;
      setState(() {
        _isSavingPlace = false;
        _statusTitle = '장소 저장 완료';
        _statusSubtitle = '${place.name}을(를) $trimmedName(으)로 저장했습니다.';
      });
      _showMessage('$trimmedName 저장 완료');
      await _speakLowerPriorityAnnouncement(
        '${place.name}을 $trimmedName(으)로 저장했습니다.',
      );
      return true;
    } catch (error) {
      if (!mounted) return false;
      setState(() {
        _isSavingPlace = false;
        _statusTitle = '장소 저장 실패';
        _statusSubtitle = error is NavigationFailure ? error.spoken : error.toString();
      });
      _showMessage('장소 저장 실패');
      await _speakLowerPriorityAnnouncement(
        error is NavigationFailure && error.spoken.contains('네트워크')
            ? '장소 검색에 실패해 저장하지 못했습니다. 네트워크 상태를 확인해 주세요.'
            : '$trimmedKeyword을 찾지 못해 저장하지 못했습니다.',
      );
      return false;
    }
  }

  /// 음성 원문에서 저장 이름을 추정한다. GPT가 placeName을 비워 보냈을 때의 보조.
  String _guessPlaceNameFromText(String rawText) {
    final String key = _normalizePlaceKey(rawText);
    const List<String> candidates = <String>['집', '회사', '직장', '학교', '병원', '약국', '교회', '마트', '편의점'];
    for (final String candidate in candidates) {
      if (key.contains(candidate)) {
        return candidate == '직장' ? '회사' : candidate;
      }
    }
    return '';
  }

  Future<void> _handleSavePlaceCommand(
    IntentAnalysisResult result,
    String rawText, {
    required int commandEpoch,
  }) async {
    final String name = result.placeName.trim().isNotEmpty
        ? result.placeName.trim()
        : _guessPlaceNameFromText(rawText);

    if (name.isEmpty) {
      setState(() {
        _statusTitle = '저장 이름 필요';
        _statusSubtitle = '예: "여기를 집으로 저장해줘"';
      });
      await _speakLowerPriorityAnnouncement(
        '저장할 이름을 함께 말해주세요. 예를 들어 여기를 집으로 저장해줘라고 말하면 됩니다.',
      );
      return;
    }

    if (result.destination.trim().isNotEmpty) {
      await _searchAndSavePlace(name: name, keyword: result.destination);
    } else {
      await _saveCurrentLocationAs(name);
    }

    if (!mounted || commandEpoch != _commandEpoch) return;
    setState(() {
      _selectedTabIndex = 1;
    });
  }

  /// 저장된 장소 카드에서 눌러서 바로 길안내를 시작한다.
  Future<void> _navigateToSavedPlace(SavedPlace place) async {
    if (_isAnalyzing || _isFindingRoute) {
      _showMessage('현재 작업이 끝난 후 다시 시도해주세요.');
      return;
    }
    _commandEpoch += 1;
    final int commandEpoch = _commandEpoch;
    setState(() {
      _recognizedText = '${place.name}으로 안내해줘';
      _statusTitle = '저장된 장소로 안내';
      _statusSubtitle = '${place.name}까지 경로를 찾습니다.';
    });
    await _findRouteWithKakao(commandEpoch: commandEpoch, savedPlace: place);
  }

  Future<void> _confirmDeleteSavedPlace(SavedPlace place) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('${place.name} 삭제'),
        content: Text('${place.address}\n\n저장된 장소에서 삭제할까요?'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFB42318)),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _finishDeleteSavedPlace(place);
    }
  }

  /// 이름(필수)과 검색어(선택)를 입력받는 공용 다이얼로그.
  /// 반환: {'name': ..., 'keyword': ...} 또는 null(취소)
  ///
  /// TextEditingController는 `_PlaceInputDialog`가 자기 dispose에서 정리한다.
  /// 예전처럼 showDialog가 끝나자마자 여기서 dispose하면 다이얼로그가 사라지는
  /// 애니메이션 중에 TextField가 이미 버려진 컨트롤러를 쓰게 되어
  /// "'_dependents.isEmpty': is not true" 빨간 화면이 났다.
  Future<Map<String, String>?> _showPlaceInputDialog({
    required String title,
    required bool askKeyword,
  }) {
    return showDialog<Map<String, String>>(
      context: context,
      builder: (BuildContext context) =>
          _PlaceInputDialog(title: title, askKeyword: askKeyword),
    );
  }

  Future<void> _promptSaveCurrentLocation() async {
    final Map<String, String>? input = await _showPlaceInputDialog(
      title: '현재 위치 저장',
      askKeyword: false,
    );
    if (input == null) return;
    await _saveCurrentLocationAs(input['name'] ?? '');
  }

  Future<void> _promptSearchAndSavePlace() async {
    final Map<String, String>? input = await _showPlaceInputDialog(
      title: '장소 검색해서 저장',
      askKeyword: true,
    );
    if (input == null) return;
    await _searchAndSavePlace(
      name: input['name'] ?? '',
      keyword: input['keyword'] ?? '',
    );
  }

  /// 카카오 도보 경로가 TOO_FAR_AWAY를 돌려주기 시작하는 직선거리(약 30~35km)보다
  /// 넉넉히 큰 값. 이보다 멀면 API를 부르지 않고 바로 "너무 멀다"고 알린다.
  static const double _maxWalkRouteStraightMeters = 40000;

  /// [destination]은 GPT가 뽑은 검색어. 비어 있을 때만 음성 원문에서 규칙으로 추출한다.
  Future<void> _findRouteWithKakao({
    required int commandEpoch,
    SavedPlace? savedPlace,
    String destination = '',
  }) async {
    if (_kakaoRestApiKey.trim().isEmpty ||
        _kakaoRestApiKey.contains('여기에_카카오')) {
      setState(() {
        _routeDestinationName = '-';
        _routeSummary = '카카오 REST API 키가 입력되지 않았습니다.';
        _routeFirstGuide = 'secrets.json의 KAKAO_REST_API_KEY 값을 설정하세요.';
        _routePoints = [];
      });

      await _stopNavigation(resetGuide: true);
      await _clearRouteOnKakaoMap();
      _showMessage('카카오 REST API 키를 입력해주세요.');
      return;
    }

    final String gptKeyword = _cleanDestinationKeyword(destination);
    final String keyword = savedPlace?.name ??
        (gptKeyword.isNotEmpty
            ? gptKeyword
            : _extractDestinationKeyword(_recognizedText));
    print('[NAV] keyword="$keyword" (gpt="$destination", saved=${savedPlace?.name})');

    if (keyword.isEmpty) {
      setState(() {
        _routeDestinationName = '-';
        _routeSummary = '목적지를 찾을 수 없습니다.';
        _routeFirstGuide = '예: 근처 편의점으로 안내해줘';
        _routePoints = [];
      });

      await _stopNavigation(resetGuide: true);
      await _clearRouteOnKakaoMap();
      _showMessage('목적지를 인식하지 못했습니다.');
      return;
    }

    try {
      await _stopNavigation(resetGuide: false);
      await _clearRouteOnKakaoMap();

      setState(() {
        _selectedTabIndex = 1;
        _isFindingRoute = true;
        _statusTitle = '카카오맵 길찾기 중';
        _statusSubtitle = savedPlace != null
            ? '저장된 장소 $keyword까지 경로를 찾고 있습니다.'
            : '$keyword 위치를 검색하고 있습니다.';
        _routeDestinationName = keyword;
        _routeSummary = '검색 중...';
        _routeFirstGuide = '-';
        _navigationGuide = '경로를 검색하고 있습니다.';
        _navigationDistanceText = '-';
      });

      final Position currentPosition = await _getCurrentPosition();
      if (!mounted || commandEpoch != _commandEpoch) return;

      final KakaoPlace place = savedPlace != null
          ? savedPlace.toKakaoPlace()
          : await _searchKakaoPlace(
              keyword: keyword,
              longitude: currentPosition.longitude,
              latitude: currentPosition.latitude,
            );

      if (savedPlace != null) {
        print('[SAVED PLACE] navigate to ${savedPlace.name} '
            '(${savedPlace.latitude}, ${savedPlace.longitude})');
        _recordAppLog('place', '저장된 장소로 안내 시작: ${savedPlace.name}');
      }

      if (!mounted || commandEpoch != _commandEpoch) return;

      // 도보 경로 API 한계(직선 약 30~35km)를 크게 넘는 곳은 호출하지 않고 바로 알린다.
      // 30~40km 사이는 API에 맡기고, TOO_FAR_AWAY가 오면 같은 문장을 읽는다.
      final double straightDistance = Geolocator.distanceBetween(
        currentPosition.latitude,
        currentPosition.longitude,
        place.latitude,
        place.longitude,
      );
      print('[NAV] ${place.name} 직선거리 ${straightDistance.round()}m');
      if (straightDistance > _maxWalkRouteStraightMeters) {
        throw NavigationFailure(
          '${place.name}은 여기서 약 ${_formatKilometers(straightDistance)} 떨어져 있어 '
          '도보로 안내할 수 없습니다.',
          detail: '직선거리 ${straightDistance.round()}m > '
              '${_maxWalkRouteStraightMeters.round()}m',
        );
      }

      final KakaoWalkRoute route = await _getKakaoWalkRoute(
        startX: currentPosition.longitude,
        startY: currentPosition.latitude,
        endX: place.longitude,
        endY: place.latitude,
        endName: place.name,
      );

      if (!mounted || commandEpoch != _commandEpoch) return;

      setState(() {
        _isFindingRoute = false;
        _routeDestinationName = place.name;
        _routeSummary =
            '총 거리 ${route.totalDistance}m / 예상 시간 ${_formatSeconds(route.totalTime)}';
        _routeTotalDistance = route.totalDistance;
        _routeTotalTime = route.totalTime;
        _routeFirstGuide = route.firstGuide;
        _routePoints = route.points;
        _navigationSteps = route.navigationSteps;
        _routeDestinationLongitude = place.longitude;
        _routeDestinationLatitude = place.latitude;
        _statusTitle = '길찾기 완료';
        _statusSubtitle = '${place.name}까지의 도보 경로를 찾았습니다.';
      });

      print('수신한 경로 좌표 개수: ${route.points.length}');
      _recordAppLog(
        'navigation',
        '경로 탐색 완료: ${place.name}까지 ${route.totalDistance}m, 예상 ${_formatSeconds(route.totalTime)}',
      );
      await _drawRouteOnKakaoMap();
      if (!mounted || commandEpoch != _commandEpoch) return;
      await _startNavigation();
      _showMessage('카카오맵 길찾기 완료');
    } catch (e) {
      if (!mounted || commandEpoch != _commandEpoch) return;

      final String spoken = e is NavigationFailure
          ? e.spoken
          : '경로를 찾지 못했습니다. 네트워크 상태를 확인해 주세요.';
      final String detail = e is NavigationFailure ? e.detail : e.toString();

      setState(() {
        _isFindingRoute = false;
        _routeSummary = '길찾기 실패';
        _routeFirstGuide = spoken;
        _routePoints = [];
        _navigationSteps = [];
        _routeDestinationLongitude = null;
        _routeDestinationLatitude = null;
        _navigationGuide = '경로 안내를 시작할 수 없습니다.';
        _upcomingNavigationGuide = '';
        _navigationDistanceText = '-';
        _routeTotalDistance = 0;
        _routeTotalTime = 0;
        _statusTitle = '길찾기 실패';
        _statusSubtitle = spoken;
      });

      await _clearRouteOnKakaoMap();
      print('카카오맵 길찾기 오류: $detail');
      _recordAppLog('navigation', '길찾기 실패: $spoken');
      _showMessage('카카오맵 길찾기 실패');
      // 화면만 바뀌면 시각장애인 사용자는 실패를 알 수 없으므로 음성으로도 알린다.
      // 위험 안내 중이면 해제 뒤 주요 안내로 읽는다.
      await _speakLowerPriorityAnnouncement(spoken, holdDuringHazard: true);
    }
  }

  Future<void> _startNavigation() async {
    await _navigationPositionSubscription?.cancel();
    _navigationPositionSubscription = null;
    _isNavigationPaused = false;

    if (_navigationSteps.isEmpty) {
      if (mounted) {
        setState(() {
          _selectedTabIndex = 1;
          _isNavigating = false;
          _navigationGuide = _routeFirstGuide;
          _upcomingNavigationGuide = '';
          _navigationDistanceText = '-';
        });
      }
      await _speakLowerPriorityAnnouncement(
        '경로를 찾았습니다. $_routeFirstGuide',
      );
      return;
    }

    _currentNavigationStepIndex = 0;
    _lastDistanceAnnouncementBucket = -1;
    _offRouteConsecutiveCount = 0;
    _lastRerouteAt = null;
    _previousRouteProgressPosition = null;
    _reverseDirectionConsecutiveCount = 0;
    _lastReverseDirectionAnnouncementAt = null;
    _previousNavigationPosition = null;
    _latestNavigationPosition = null;
    _currentTravelHeading = _deviceHeading;
    _lastCompassGuidanceAt = null;
    _lastDirectionAnnouncementKey = '';
    _lastDirectionAnnouncementAt = DateTime.now();
    _arrivalApproachAnnounced = false;
    _arrivalDirectionAnnounced = false;

    final KakaoNavigationStep firstStep = _navigationSteps.first;
    _lastDistanceAnnouncementBucket =
        _distanceAnnouncementBucket(firstStep.distance);
    final String firstDirection = _directionInstructionForStep(0);
    final String firstFullGuide = _currentGuideForStep(
      0,
      firstDirection,
      firstStep.distance,
    );
    final String firstUpcomingGuide = _upcomingGuideForStep(
      0,
      firstStep.distance,
    );
    _lastDirectionAnnouncementKey = firstDirection;

    if (mounted) {
      setState(() {
        _selectedTabIndex = 1;
        _isNavigating = true;
        _navigationGuide = firstFullGuide;
        _upcomingNavigationGuide = firstUpcomingGuide;
        _navigationDistanceText =
            firstStep.distance > 0 ? '${firstStep.distance}m' : '-';
      });
    }

    // 이전 물건 찾기 상태를 완전히 정리한 뒤 길안내를 시작한다.
    // 물건을 찾던 중이었다면 어떤 기능이 끝나고 무엇이 시작되는지 먼저 알린다.
    final String previousObjectLabel = _activeObjectLabel.trim().isEmpty
        ? _activeObjectTarget.trim()
        : _activeObjectLabel.trim();
    final bool wasSearchingObject = previousObjectLabel.isNotEmpty;
    await _stopObjectSearchSilently(clearDisplay: true);

    final String transitionPrefix = wasSearchingObject
        ? '$previousObjectLabel 찾기를 멈추고 길안내를 시작합니다. '
        : '';
    if (wasSearchingObject) {
      _recordAppLog(
        'navigation',
        '물건 찾기($previousObjectLabel) 종료 후 길안내 시작: $_routeDestinationName',
      );
    }

    await _speakLowerPriorityAnnouncement(
      '$transitionPrefix'
      '$_routeDestinationName까지 총 $_routeTotalDistance미터, '
      '예상 ${_formatSeconds(_routeTotalTime)}입니다. '
      '도보 안내를 시작합니다. $firstFullGuide '
      '${firstUpcomingGuide.isEmpty ? '' : firstUpcomingGuide}',
      holdDuringHazard: true,
    );

    _startNavigationPositionStream();
  }

  /// 길안내용 GPS 스트림을 (재)구독한다. 길안내 시작과 일시정지 후 재개에서 같이 쓴다.
  void _startNavigationPositionStream() {
    // Android: 포그라운드 서비스로 GPS 스트림을 유지해 화면이 꺼지거나
    // 앱이 가려져도 길안내가 끊기지 않게 한다. (알림 표시줄에 안내 중 표시)
    final LocationSettings locationSettings = AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 3,
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: 'SmartCane 길안내 중',
        notificationText: '위치를 추적하며 음성 안내를 계속합니다.',
        enableWakeLock: true,
      ),
    );

    _navigationPositionSubscription = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(
      (Position position) {
        unawaited(_handleNavigationPosition(position));
      },
      onError: (Object error) {
        if (!mounted) return;
        setState(() {
          _navigationDistanceText = 'GPS 확인 필요';
        });
        print('실시간 위치 수신 오류: $error');
      },
    );
  }

  /// 길안내 중 물건 찾기 명령이 오면 길안내를 잠시 멈춘다.
  /// 경로·목적지·현재 단계는 그대로 두고 GPS 추적과 진동·음성 안내만 멈춘다.
  /// 진동모터와 음성은 한 채널이라 두 기능이 같이 돌면 "왼쪽" 진동이
  /// 길안내인지 물건 방향인지 구분할 수 없기 때문이다.
  Future<void> _pauseNavigationForObjectSearch(String targetLabel) async {
    if (!_isNavigationGuidanceActive) return;

    await _navigationPositionSubscription?.cancel();
    _navigationPositionSubscription = null;
    _isNavigationPaused = true;

    await _sendNavigationMotorCommand('STOP', force: true);
    await _stopAllAudioOutput(stopSpeechRecognition: false);

    if (mounted) {
      setState(() {
        _selectedTabIndex = 0;
        _navigationMotorStatus = '물건 찾기 중 · 길안내 잠시 멈춤';
        _navigationMotorVisualTimer?.cancel();
        _activeNavigationMotorAction = '';
      });
    }

    _recordAppLog(
      'navigation',
      '길안내 잠시 멈춤(물건 찾기: $targetLabel) · 목적지 $_routeDestinationName 유지',
    );
    print('[NAV] paused for object search: $targetLabel');

    await _speakLowerPriorityAnnouncement(
      '길안내를 잠시 멈추고 $targetLabel을 찾습니다. '
      '다 찾으면 그만이라고 말씀해 주세요. 길안내를 이어서 시작합니다.',
      holdDuringHazard: true,
    );
  }

  /// 물건 찾기를 마치면 멈춰 두었던 길안내를 같은 경로·같은 단계에서 이어간다.
  /// [leadText]는 "물건 찾기를 마쳤습니다." 대신 읽을 앞말이다.
  /// (예: 지원하지 않는 물건이라 찾기가 바로 끝난 경우)
  Future<void> _resumeNavigationAfterObjectSearch({String? leadText}) async {
    if (!_isNavigating || !_isNavigationPaused) return;

    if (_navigationSteps.isEmpty ||
        _currentNavigationStepIndex >= _navigationSteps.length) {
      _isNavigationPaused = false;
      await _stopNavigation(resetGuide: true);
      return;
    }

    _isNavigationPaused = false;

    // 멈춰 있던 동안 걸었을 수 있으므로 이전 위치 기반 판정값을 비운다.
    // 경로를 많이 벗어났다면 재개 뒤 기존 이탈 판정이 자연스럽게 재탐색한다.
    _previousNavigationPosition = null;
    _previousRouteProgressPosition = null;
    _latestNavigationPosition = null;
    _reverseDirectionConsecutiveCount = 0;
    _lastReverseDirectionAnnouncementAt = null;
    _offRouteConsecutiveCount = 0;
    _lastCompassGuidanceAt = null;
    _lastDirectionAnnouncementAt = DateTime.now();
    _pendingNavigationBleCommand = '';
    _pendingNavigationBleCount = 0;

    if (mounted) {
      setState(() {
        _selectedTabIndex = 1;
        _navigationMotorStatus = '진동 안내 대기';
        _statusTitle = '길안내 재개';
        _statusSubtitle = '$_routeDestinationName까지 안내를 이어서 시작합니다.';
      });
    }

    _startNavigationPositionStream();

    _recordAppLog(
      'navigation',
      '물건 찾기 종료 후 길안내 재개: $_routeDestinationName',
    );
    print('[NAV] resumed after object search');

    final String lead = (leadText ?? '').trim().isEmpty
        ? '물건 찾기를 마쳤습니다.'
        : leadText!.trim();

    await _speakLowerPriorityAnnouncement(
      '$lead $_routeDestinationName까지 길안내를 이어서 시작합니다. '
      '$_navigationGuide',
      holdDuringHazard: true,
    );
  }

  /// 물건 찾기를 끝내고(지팡이에 STOP) 멈춰 둔 길안내를 이어간다.
  Future<void> _finishObjectSearchAndResumeNavigation({
    String? leadText,
  }) async {
    await _stopObjectSearchSilently(clearDisplay: true);
    await _resumeNavigationAfterObjectSearch(leadText: leadText);
  }

  Future<void> _stopNavigation({required bool resetGuide}) async {
    await _navigationPositionSubscription?.cancel();
    _navigationPositionSubscription = null;

    if (_isNavigating && !_isNavigationPaused) {
      await _sendNavigationMotorCommand('STOP', force: true);
    }

    await _stopAllAudioOutput(stopSpeechRecognition: false);

    if (!mounted) return;

    setState(() {
      _isNavigating = false;
      _isNavigationPaused = false;
      _isRerouting = false;
      _navigationSteps = [];
      _currentNavigationStepIndex = 0;
      _lastDistanceAnnouncementBucket = -1;
      _offRouteConsecutiveCount = 0;
      _previousRouteProgressPosition = null;
      _reverseDirectionConsecutiveCount = 0;
      _lastReverseDirectionAnnouncementAt = null;
      _previousNavigationPosition = null;
      _latestNavigationPosition = null;
      _currentTravelHeading = null;
      _lastCompassGuidanceAt = null;
      _lastDirectionAnnouncementKey = '';
      _lastDirectionAnnouncementAt = null;
      _arrivalApproachAnnounced = false;
      _arrivalDirectionAnnounced = false;
      _navigationMotorStatus = resetGuide ? '진동 안내 대기' : '진동 정지';
      _navigationMotorVisualTimer?.cancel();
      _activeNavigationMotorAction = '';

      if (resetGuide) {
        _routeDestinationLongitude = null;
        _routeDestinationLatitude = null;
        _navigationGuide = '경로를 검색하면 음성 안내가 시작됩니다.';
        _upcomingNavigationGuide = '';
        _navigationDistanceText = '-';
        _routeTotalDistance = 0;
        _routeTotalTime = 0;
      }
    });
  }

  Future<void> _handleNavigationPosition(Position position) async {
    if (!mounted ||
        !_isNavigationGuidanceActive ||
        _navigationSteps.isEmpty ||
        _currentNavigationStepIndex >= _navigationSteps.length) {
      return;
    }

    final KakaoNavigationStep step =
        _navigationSteps[_currentNavigationStepIndex];
    final double distance = Geolocator.distanceBetween(
      position.latitude,
      position.longitude,
      step.latitude,
      step.longitude,
    );
    final int roundedDistance = distance.round();

    setState(() {
      _navigationDistanceText = '${roundedDistance}m';
    });

    _latestNavigationPosition = position;

    // 좌/우 안내는 휴대폰 방향을 사용할 수 있지만,
    // 경로 진행/역방향 판정은 실제 GPS 이동 벡터를 사용한다.
    final double? gpsMovementHeading =
        _gpsMovementHeadingForRouteProgress(position);
    final double? travelHeading = _updateTravelHeading(position);

    _updateKakaoMapCurrentPosition(position);

    // 정확도가 너무 낮을 때는 잘못된 회전/도착 안내로 넘어가지 않는다.
    if (position.accuracy > 35) {
      setState(() {
        _navigationDistanceText = 'GPS 오차 ±${position.accuracy.round()}m';
      });
      return;
    }

    // 지정된 경로를 그대로 밟지 않아도 목적지 근처에 도착하면 완료한다.
    final double? destinationLongitude = _routeDestinationLongitude;
    final double? destinationLatitude = _routeDestinationLatitude;

    if (destinationLongitude != null && destinationLatitude != null) {
      double destinationDistance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        destinationLatitude,
        destinationLongitude,
      );

      // 장소 검색 좌표가 건물 중심일 수 있으므로 경로의 실제 끝점도 확인한다.
      if (_routePoints.isNotEmpty) {
        final List<double> routeEnd = _routePoints.last;
        final double routeEndDistance = Geolocator.distanceBetween(
          position.latitude,
          position.longitude,
          routeEnd[1],
          routeEnd[0],
        );
        destinationDistance = math.min(
          destinationDistance,
          routeEndDistance,
        ).toDouble();
      }

      if (destinationDistance <= 18) {
        unawaited(_completeNavigation());
        return;
      }

      if (destinationDistance <= 35) {
        final String? destinationSide = _destinationSideInstruction(
          position,
          destinationLatitude,
          destinationLongitude,
        );

        final bool shouldAnnounceApproach = !_arrivalApproachAnnounced;
        final bool shouldAnnounceDirection = destinationSide != null &&
            !_arrivalDirectionAnnounced;

        if (shouldAnnounceApproach || shouldAnnounceDirection) {
          _arrivalApproachAnnounced = true;
          if (destinationSide != null) {
            _arrivalDirectionAnnounced = true;
          }

          final String approachGuide = destinationSide == null
              ? '잠시 후 목적지 주변입니다. 앞으로 두세 걸음 이동하면 '
                  '목적지의 좌우 방향을 안내합니다. '
                  '출입구와 주변 장애물을 확인하세요.'
              : '잠시 후 목적지 주변입니다. 목적지는 $destinationSide에 있습니다. '
                  '출입구와 주변 장애물을 확인하세요.';
          setState(() {
            _navigationGuide = approachGuide;
            _upcomingNavigationGuide = '목적지 도착 예정';
            _navigationDistanceText = '${destinationDistance.round()}m';
          });
          unawaited(_speakLowerPriorityAnnouncement(approachGuide));
        }
      }

      // 목적지 근처에서는 회전 지점 안내보다 도착 방향과 주변 안전 확인을
      // 우선한다. 다음 GPS 위치에서도 도착 판정은 계속 수행된다.
      if (destinationDistance <= 35) return;
    }

    if (_isRerouting) return;

    final double distanceFromRoute = _distanceFromCurrentRoute(position);
    final double offRouteThreshold = math.max(
      25.0,
      position.accuracy + 10,
    ).toDouble();

    if (distanceFromRoute > offRouteThreshold) {
      _offRouteConsecutiveCount += 1;
      final int visibleCount =
          math.min(_offRouteConsecutiveCount, 3).toInt();

      setState(() {
        _navigationDistanceText =
            '경로 이탈 확인 $visibleCount/3';
      });

      final DateTime now = DateTime.now();
      final bool cooldownFinished = _lastRerouteAt == null ||
          now.difference(_lastRerouteAt!).inSeconds >= 15;

      if (_offRouteConsecutiveCount >= 3 && cooldownFinished) {
        unawaited(_rerouteFromPosition(position));
      }
      return;
    }

    if (distanceFromRoute <= offRouteThreshold - 7) {
      _offRouteConsecutiveCount = 0;
    }

    // 현재 경로와 공간적으로 가까워도 실제 이동이 반대 방향이면
    // 겹치는 과거 동선을 정상 진행으로 처리하지 않는다.
    final bool reverseDirectionDetected =
        await _handleReverseDirectionIfNeeded(
      position,
      step,
      gpsMovementHeading,
    );

    if (reverseDirectionDetected) {
      return;
    }

    final double targetBearing = _targetBearingForStep(position, step);
    final String directionInstruction = travelHeading == null
        ? _directionInstructionForStep(_currentNavigationStepIndex)
        : _relativeDirectionInstruction(
            travelHeading,
            targetBearing,
          );
    final String navigationMotorAction = travelHeading == null
        ? ''
        : _relativeNavigationMotorAction(
            travelHeading,
            targetBearing,
          );
    final String fullGuide = _currentGuideForStep(
      _currentNavigationStepIndex,
      directionInstruction,
      roundedDistance,
    );
    final String upcomingGuide = _upcomingGuideForStep(
      _currentNavigationStepIndex,
      roundedDistance,
    );

    setState(() {
      _navigationGuide = fullGuide;
      _upcomingNavigationGuide = upcomingGuide;
      _navigationDistanceText = '${roundedDistance}m';
    });

    if (navigationMotorAction.isNotEmpty) {
      unawaited(
        _sendNavigationMotorCommand(navigationMotorAction),
      );
    }

    // 회전 지점과 가까워진 것만으로 Step을 넘기지 않는다.
    // 12m 이내이면서 실제 이동 방향도 현재 경로 진행 방향과 맞아야 한다.
    if (distance <= 12 &&
        _isMovingTowardCurrentStep(
          position,
          step,
          gpsMovementHeading,
        )) {
      _reverseDirectionConsecutiveCount = 0;
      unawaited(_advanceNavigationStep());
      return;
    }

    final int bucket = _distanceAnnouncementBucket(roundedDistance);
    final DateTime now = DateTime.now();
    final bool directionChanged =
        directionInstruction != _lastDirectionAnnouncementKey;
    final Duration directionElapsed = _lastDirectionAnnouncementAt == null
        ? _navigationRepeatInterval
        : now.difference(_lastDirectionAnnouncementAt!);
    final bool directionChangeReady =
        directionChanged && directionElapsed >= _directionChangeCooldown;
    final bool sameDirectionRepeatReady =
        !directionChanged && directionElapsed >= _navigationRepeatInterval;

    if (bucket > 0 &&
        (_lastDistanceAnnouncementBucket < 0 ||
            bucket < _lastDistanceAnnouncementBucket)) {
      _lastDistanceAnnouncementBucket = bucket;
      _lastDirectionAnnouncementKey = directionInstruction;
      _lastDirectionAnnouncementAt = now;
      final String distanceGuide = _distanceVoiceGuide(
        stepIndex: _currentNavigationStepIndex,
        bucket: bucket,
        currentDirection: directionInstruction,
      );
      unawaited(
        _speakLowerPriorityAnnouncement(distanceGuide),
      );
    } else if (directionChangeReady) {
      _lastDirectionAnnouncementKey = directionInstruction;
      _lastDirectionAnnouncementAt = now;
      unawaited(_speakLowerPriorityAnnouncement(directionInstruction));
    } else if (sameDirectionRepeatReady) {
      _lastDirectionAnnouncementKey = directionInstruction;
      _lastDirectionAnnouncementAt = now;
      unawaited(_speakLowerPriorityAnnouncement(fullGuide));
    }
  }

  int _distanceAnnouncementBucket(int distance) {
    if (distance <= 25) return 20;
    if (distance <= 60) return 50;
    if (distance <= 110) return 100;
    return -1;
  }

  String _distanceVoiceGuide({
    required int stepIndex,
    required int bucket,
    required String currentDirection,
  }) {
    final String maneuver = _maneuverAfterStep(stepIndex);
    final bool hasNextStep = stepIndex + 1 < _navigationSteps.length;

    if (!hasNextStep) {
      return '목적지까지 약 $bucket미터 남았습니다. $currentDirection';
    }

    if (bucket <= 20) {
      return '잠시 후 ${_withoutFinalPeriod(maneuver)}. '
          '${_landmarkSupplement(stepIndex)}';
    }

    return '약 $bucket미터 앞에서 ${_withoutFinalPeriod(maneuver)}. '
        '그때까지 $currentDirection';
  }

  String _currentGuideForStep(
    int stepIndex,
    String directionInstruction,
    int distance,
  ) {
    final bool hasNextStep = stepIndex + 1 < _navigationSteps.length;
    if (hasNextStep && distance <= 25) {
      return '잠시 후 ${_maneuverAfterStep(stepIndex)}';
    }
    return directionInstruction;
  }

  String _upcomingGuideForStep(int stepIndex, int distance) {
    if (stepIndex + 1 >= _navigationSteps.length) {
      return '다음 안내: 목적지 주변 도착';
    }

    final int visibleDistance = math.max(0, distance).toInt();
    return '다음 안내: 약 $visibleDistance미터 앞에서 '
        '${_maneuverAfterStep(stepIndex)}';
  }

  String _maneuverAfterStep(int stepIndex) {
    final int nextIndex = stepIndex + 1;
    if (stepIndex < 0 || nextIndex >= _navigationSteps.length) {
      return '목적지까지 계속 직진하세요.';
    }

    final double? currentBearing = _navigationSteps[stepIndex].bearing;
    final double? nextBearing = _navigationSteps[nextIndex].bearing;
    if (currentBearing == null || nextBearing == null) {
      return '다음 경로를 따라 이동하세요.';
    }

    final double difference =
        (nextBearing - currentBearing + 540) % 360 - 180;
    final double absoluteDifference = difference.abs();

    if (absoluteDifference <= 25) return '계속 직진하세요.';
    if (absoluteDifference >= 165) {
      return '멈춘 뒤 뒤로 돌아 반대 방향으로 직진하세요.';
    }

    final String side = difference > 0 ? '오른쪽' : '왼쪽';
    if (absoluteDifference <= 60) {
      return '$side 앞에 이어지는 길로 진입하세요.';
    }
    if (absoluteDifference <= 125) {
      return difference > 0 ? '우회전하세요.' : '좌회전하세요.';
    }
    return '$side 뒤쪽 길로 크게 돌아가세요.';
  }

  String _turnInstructionAtStep(int stepIndex) {
    if (stepIndex <= 0 || stepIndex >= _navigationSteps.length) {
      return _directionInstructionForStep(stepIndex);
    }

    final double? previousBearing =
        _navigationSteps[stepIndex - 1].bearing;
    final double? currentBearing = _navigationSteps[stepIndex].bearing;
    if (previousBearing == null || currentBearing == null) {
      return _directionInstructionForStep(stepIndex);
    }

    final double difference =
        (currentBearing - previousBearing + 540) % 360 - 180;
    final double absoluteDifference = difference.abs();
    if (absoluteDifference <= 25) return '계속 직진하세요.';
    if (absoluteDifference >= 165) {
      return '멈춘 뒤 뒤로 돌아 반대 방향으로 직진하세요.';
    }

    final String side = difference > 0 ? '오른쪽' : '왼쪽';
    if (absoluteDifference <= 60) {
      return '$side 앞에 이어지는 길로 진입하세요.';
    }
    if (absoluteDifference <= 125) {
      return difference > 0 ? '우회전하세요.' : '좌회전하세요.';
    }
    return '$side 뒤쪽 길로 크게 돌아가세요.';
  }

  String _turnNavigationMotorActionAtStep(int stepIndex) {
    if (stepIndex <= 0 || stepIndex >= _navigationSteps.length) {
      return 'FORWARD';
    }

    final double? previousBearing =
        _navigationSteps[stepIndex - 1].bearing;
    final double? currentBearing = _navigationSteps[stepIndex].bearing;
    if (previousBearing == null || currentBearing == null) {
      return 'FORWARD';
    }

    return _relativeNavigationMotorAction(
      previousBearing,
      currentBearing,
    );
  }

  String _landmarkSupplement(int stepIndex) {
    if (stepIndex < 0 || stepIndex >= _navigationSteps.length) return '';
    final String guidance = _navigationSteps[stepIndex].guidance.trim();
    if (guidance.isEmpty || RegExp(r'^\d+m 이동$').hasMatch(guidance)) {
      return '';
    }

    final RegExpMatch? landmarkMatch =
        RegExp(r'^(.+?)까지\s*\d+m\s*이동').firstMatch(guidance);
    if (landmarkMatch != null) {
      return '${landmarkMatch.group(1)} 방면입니다.';
    }

    return '${_withoutFinalPeriod(guidance)}.';
  }

  String _withoutFinalPeriod(String value) {
    return value.trim().replaceFirst(RegExp(r'[.!?]+$'), '');
  }

  String? _destinationSideInstruction(
    Position position,
    double destinationLatitude,
    double destinationLongitude,
  ) {
    final double destinationBearing = _bearingBetween(
      position.latitude,
      position.longitude,
      destinationLatitude,
      destinationLongitude,
    );
    final double? heading = _currentTravelHeading;
    if (heading == null) return null;

    final double difference =
        (destinationBearing - heading + 540) % 360 - 180;
    final double absoluteDifference = difference.abs();
    if (absoluteDifference <= 35) return '앞쪽';
    if (absoluteDifference >= 145) return '뒤쪽';
    return difference > 0 ? '오른쪽' : '왼쪽';
  }

  double? _updateTravelHeading(Position position) {
    // 휴대폰 상단이 향한 방향을 최우선으로 사용한다. 최근 센서값이
    // 없을 때에만 GPS의 실제 이동 방향으로 자동 대체한다.
    final DateTime? deviceHeadingAt = _lastDeviceHeadingAt;
    if (_deviceHeading != null &&
        deviceHeadingAt != null &&
        DateTime.now().difference(deviceHeadingAt) <
            const Duration(seconds: 3)) {
      _previousNavigationPosition = position;
      _currentTravelHeading = _deviceHeading;
      return _currentTravelHeading;
    }

    final Position? previous = _previousNavigationPosition;
    double? heading;

    if (previous != null) {
      final double movedDistance = Geolocator.distanceBetween(
        previous.latitude,
        previous.longitude,
        position.latitude,
        position.longitude,
      );

      if (movedDistance >= 2.5) {
        heading = _bearingBetween(
          previous.latitude,
          previous.longitude,
          position.latitude,
          position.longitude,
        );
      }
    }

    // 첫 위치이거나 이동 거리가 짧으면 GPS가 제공하는 진행 방향을 사용한다.
    if (heading == null &&
        position.speed >= 0.5 &&
        position.heading.isFinite &&
        position.heading >= 0 &&
        position.heading <= 360) {
      heading = position.heading;
    }

    _previousNavigationPosition = position;

    if (heading != null) {
      _currentTravelHeading = heading;
    }

    return _currentTravelHeading;
  }

  double _bearingBetween(
    double startLatitude,
    double startLongitude,
    double endLatitude,
    double endLongitude,
  ) {
    final double startLat = startLatitude * math.pi / 180;
    final double endLat = endLatitude * math.pi / 180;
    final double longitudeDifference =
        (endLongitude - startLongitude) * math.pi / 180;
    final double y = math.sin(longitudeDifference) * math.cos(endLat);
    final double x = math.cos(startLat) * math.sin(endLat) -
        math.sin(startLat) *
            math.cos(endLat) *
            math.cos(longitudeDifference);

    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  double _targetBearingForStep(
    Position position,
    KakaoNavigationStep step,
  ) {
    if (step.pathPoints.length >= 2) {
      int nearestIndex = 0;
      double nearestDistance = double.infinity;

      for (int i = 0; i < step.pathPoints.length; i++) {
        final List<double> point = step.pathPoints[i];
        final double pointDistance = Geolocator.distanceBetween(
          position.latitude,
          position.longitude,
          point[1],
          point[0],
        );
        if (pointDistance < nearestDistance) {
          nearestDistance = pointDistance;
          nearestIndex = i;
        }
      }

      int targetIndex = nearestIndex;
      for (int i = nearestIndex + 1; i < step.pathPoints.length; i++) {
        targetIndex = i;
        final List<double> point = step.pathPoints[i];
        final double pointDistance = Geolocator.distanceBetween(
          position.latitude,
          position.longitude,
          point[1],
          point[0],
        );
        if (pointDistance >= 8) break;
      }

      final List<double> target = step.pathPoints[targetIndex];
      if (targetIndex > nearestIndex || nearestDistance > 2) {
        return _bearingBetween(
          position.latitude,
          position.longitude,
          target[1],
          target[0],
        );
      }
    }

    return _bearingBetween(
      position.latitude,
      position.longitude,
      step.latitude,
      step.longitude,
    );
  }

  String _relativeDirectionInstruction(
    double travelHeading,
    double targetBearing,
  ) {
    final double difference =
        (targetBearing - travelHeading + 540) % 360 - 180;
    final double absoluteDifference = difference.abs();

    if (absoluteDifference <= 30) {
      return '현재 방향 그대로 직진하세요.';
    }
    if (absoluteDifference >= 150) {
      return '진행 방향이 반대입니다. 멈춘 뒤 뒤로 돌아 직진하세요.';
    }

    final String side = difference > 0 ? '오른쪽' : '왼쪽';
    if (absoluteDifference <= 70) {
      return '몸을 $side으로 조금 돌린 뒤 직진하세요.';
    }
    return '몸을 $side으로 돌린 뒤 직진하세요.';
  }

  String _relativeNavigationMotorAction(
    double travelHeading,
    double targetBearing,
  ) {
    final double difference =
        (targetBearing - travelHeading + 540) % 360 - 180;
    final double absoluteDifference = difference.abs();

    if (absoluteDifference <= 30) return 'FORWARD';
    if (absoluteDifference >= 150) return 'UTURN';
    if (difference > 0) {
      return 'RIGHT';
    }
    return 'LEFT';
  }

  String _directionInstructionForStep(int stepIndex) {
    if (stepIndex < 0 || stepIndex >= _navigationSteps.length) {
      return '경로를 따라 이동하세요.';
    }

    final KakaoNavigationStep step = _navigationSteps[stepIndex];
    final double? stepBearing = step.bearing;

    if (_currentTravelHeading != null && stepBearing != null) {
      return _relativeDirectionInstruction(
        _currentTravelHeading!,
        stepBearing,
      );
    }

    if (stepIndex > 0 && stepBearing != null) {
      final double? previousBearing =
          _navigationSteps[stepIndex - 1].bearing;
      if (previousBearing != null) {
        return _relativeDirectionInstruction(
          previousBearing,
          stepBearing,
        );
      }
    }

    return '출발 방향 확인을 위해 앞으로 두세 걸음 이동하세요.';
  }

  double _distanceFromPolyline(
    Position position,
    List<List<double>> points,
  ) {
    if (points.length < 2) return double.infinity;

    final double latitudeScale = 111320;
    final double longitudeScale =
        111320 * math.cos(position.latitude * math.pi / 180);
    double minimumDistance = double.infinity;

    for (int i = 0; i < points.length - 1; i++) {
      final List<double> start = points[i];
      final List<double> end = points[i + 1];

      final double startX =
          (start[0] - position.longitude) * longitudeScale;
      final double startY =
          (start[1] - position.latitude) * latitudeScale;
      final double endX =
          (end[0] - position.longitude) * longitudeScale;
      final double endY =
          (end[1] - position.latitude) * latitudeScale;

      final double segmentX = endX - startX;
      final double segmentY = endY - startY;
      final double segmentLengthSquared =
          segmentX * segmentX + segmentY * segmentY;

      double ratio = 0;
      if (segmentLengthSquared > 0) {
        ratio = (-(startX * segmentX + startY * segmentY) /
                segmentLengthSquared)
            .clamp(0.0, 1.0)
            .toDouble();
      }

      final double closestX = startX + ratio * segmentX;
      final double closestY = startY + ratio * segmentY;
      final double distance = math.sqrt(
        closestX * closestX + closestY * closestY,
      );

      if (distance < minimumDistance) {
        minimumDistance = distance;
      }
    }

    return minimumDistance;
  }

  double _distanceFromCurrentRoute(Position position) {
    if (_routePoints.length < 2) return double.infinity;

    // 전체 경로를 비교하면 이미 지나온 구간과 겹치는 지점에서
    // 과거 경로를 현재 정상 경로로 오인할 수 있다.
    // 현재 Step + 다음 Step만 현재 진행 구간으로 취급한다.
    final List<List<double>> activePoints = <List<double>>[];

    if (_currentNavigationStepIndex >= 0 &&
        _currentNavigationStepIndex < _navigationSteps.length) {
      activePoints.addAll(
        _navigationSteps[_currentNavigationStepIndex].pathPoints,
      );

      final int nextIndex = _currentNavigationStepIndex + 1;
      if (nextIndex < _navigationSteps.length) {
        final List<List<double>> nextPoints =
            _navigationSteps[nextIndex].pathPoints;

        if (nextPoints.isNotEmpty) {
          if (activePoints.isNotEmpty &&
              activePoints.last[0] == nextPoints.first[0] &&
              activePoints.last[1] == nextPoints.first[1]) {
            activePoints.addAll(nextPoints.skip(1));
          } else {
            activePoints.addAll(nextPoints);
          }
        }
      }
    }

    // Step별 geometry가 없는 경우에만 기존 전체 경로를 사용한다.
    if (activePoints.length < 2) {
      return _distanceFromPolyline(position, _routePoints);
    }

    return _distanceFromPolyline(position, activePoints);
  }

  double? _gpsMovementHeadingForRouteProgress(Position position) {
    final Position? previous = _previousRouteProgressPosition;
    _previousRouteProgressPosition = position;

    if (previous == null) return null;

    final double movedDistance = Geolocator.distanceBetween(
      previous.latitude,
      previous.longitude,
      position.latitude,
      position.longitude,
    );

    // GPS 흔들림을 실제 이동으로 오인하지 않는다.
    if (movedDistance < 3.0) return null;

    return _bearingBetween(
      previous.latitude,
      previous.longitude,
      position.latitude,
      position.longitude,
    );
  }

  double _absoluteHeadingDifference(
    double headingA,
    double headingB,
  ) {
    return ((headingA - headingB + 540) % 360 - 180).abs();
  }

  bool _isMovingTowardCurrentStep(
    Position position,
    KakaoNavigationStep step,
    double? gpsMovementHeading,
  ) {
    if (gpsMovementHeading == null) return true;

    final double targetBearing = _targetBearingForStep(position, step);
    final double difference = _absoluteHeadingDifference(
      gpsMovementHeading,
      targetBearing,
    );

    // 교차로/회전 지점의 GPS 오차를 감안하여 여유를 둔다.
    return difference <= 110;
  }

  Future<bool> _handleReverseDirectionIfNeeded(
    Position position,
    KakaoNavigationStep step,
    double? gpsMovementHeading,
  ) async {
    if (gpsMovementHeading == null) return false;

    final double routeBearing = _targetBearingForStep(position, step);
    final double difference = _absoluteHeadingDifference(
      gpsMovementHeading,
      routeBearing,
    );

    // 실제 이동 방향이 경로 진행 방향과 125도 이상 다를 때만 누적한다.
    if (difference >= 125) {
      _reverseDirectionConsecutiveCount += 1;
    } else if (difference <= 95) {
      _reverseDirectionConsecutiveCount = 0;
    }

    if (_reverseDirectionConsecutiveCount < 3) {
      return false;
    }

    final DateTime now = DateTime.now();
    final bool canAnnounce =
        _lastReverseDirectionAnnouncementAt == null ||
        now.difference(_lastReverseDirectionAnnouncementAt!) >=
            const Duration(seconds: 8);

    if (canAnnounce) {
      _lastReverseDirectionAnnouncementAt = now;

      if (mounted) {
        setState(() {
          _navigationGuide =
              '진행 방향이 반대입니다. 안전한 곳에서 방향을 돌려주세요.';
          _upcomingNavigationGuide =
              '방향을 바로잡지 않으면 현재 위치에서 경로를 다시 찾습니다.';
          _navigationDistanceText = '역방향 감지';
        });
      }

      await _sendNavigationMotorCommand('UTURN');
      await _speakLowerPriorityAnnouncement(
        '진행 방향이 반대입니다. 안전한 곳에서 방향을 돌려주세요.',
      );
    }

    // 계속 반대 방향으로 걸으면 겹치는 과거 경로를 따라가지 않고
    // 현재 위치 기준으로 새 경로를 계산한다.
    if (_reverseDirectionConsecutiveCount >= 5) {
      _reverseDirectionConsecutiveCount = 0;

      final bool cooldownFinished = _lastRerouteAt == null ||
          now.difference(_lastRerouteAt!).inSeconds >= 15;

      if (cooldownFinished && !_isRerouting) {
        unawaited(_rerouteFromPosition(position));
      }
    }

    return true;
  }

  Future<void> _rerouteFromPosition(Position position) async {
    if (_isRerouting || !_isNavigating) return;

    final double? destinationLongitude = _routeDestinationLongitude;
    final double? destinationLatitude = _routeDestinationLatitude;

    if (destinationLongitude == null || destinationLatitude == null) return;

    _isRerouting = true;
    _lastRerouteAt = DateTime.now();
    _offRouteConsecutiveCount = 0;

    if (mounted) {
      setState(() {
        _statusTitle = '경로 재탐색 중';
        _statusSubtitle = '현재 위치에서 목적지까지 새 경로를 찾고 있습니다.';
        _navigationGuide = '경로를 벗어나 새 경로를 찾고 있습니다.';
        _upcomingNavigationGuide = '현재 위치 기준 경로 계산 중';
        _navigationDistanceText = '재탐색 중';
      });
    }

    await _speakLowerPriorityAnnouncement('경로를 벗어났습니다. 새 경로를 탐색합니다.');
    await _sendNavigationMotorCommand('STOP', force: true);

    try {
      final KakaoWalkRoute route = await _getKakaoWalkRoute(
        startX: position.longitude,
        startY: position.latitude,
        endX: destinationLongitude,
        endY: destinationLatitude,
        endName: _routeDestinationName,
      );

      if (route.navigationSteps.isEmpty || route.points.length < 2) {
        throw Exception('재탐색된 경로의 안내 좌표가 부족합니다.');
      }

      if (!mounted || !_isNavigating) return;

      final KakaoNavigationStep firstStep = route.navigationSteps.first;
      String rerouteFullGuide = firstStep.guidance;
      setState(() {
        _routeSummary =
            '총 거리 ${route.totalDistance}m / 예상 시간 ${_formatSeconds(route.totalTime)}';
        _routeTotalDistance = route.totalDistance;
        _routeTotalTime = route.totalTime;
        _routeFirstGuide = route.firstGuide;
        _routePoints = route.points;
        _navigationSteps = route.navigationSteps;
        _currentNavigationStepIndex = 0;
        _arrivalApproachAnnounced = false;
        _arrivalDirectionAnnounced = false;
        _lastDistanceAnnouncementBucket =
            _distanceAnnouncementBucket(firstStep.distance);
        _previousNavigationPosition = position;
        _previousRouteProgressPosition = position;
        _reverseDirectionConsecutiveCount = 0;
        _lastReverseDirectionAnnouncementAt = null;
        final String firstDirection = _directionInstructionForStep(0);
        rerouteFullGuide = _currentGuideForStep(
          0,
          firstDirection,
          firstStep.distance,
        );
        _navigationGuide = rerouteFullGuide;
        _upcomingNavigationGuide = _upcomingGuideForStep(
          0,
          firstStep.distance,
        );
        _navigationDistanceText =
            firstStep.distance > 0 ? '${firstStep.distance}m' : '-';
        _statusTitle = '경로 재탐색 완료';
        _statusSubtitle = '현재 위치 기준의 새 도보 경로입니다.';
      });

      await _drawRouteOnKakaoMap();
      _latestNavigationPosition = position;
      _updateKakaoMapCurrentPosition(position);
      _lastDirectionAnnouncementKey = _directionInstructionForStep(0);
      _lastDirectionAnnouncementAt = DateTime.now();
      await _speakLowerPriorityAnnouncement('새 경로를 안내합니다. $rerouteFullGuide');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _navigationGuide = '경로 재탐색에 실패했습니다. 기존 경로를 확인하세요.';
        _upcomingNavigationGuide = '잠시 후 자동으로 다시 확인합니다.';
        _navigationDistanceText = '재탐색 실패';
        _statusTitle = '경로 재탐색 실패';
        _statusSubtitle = 'GPS와 네트워크 상태를 확인하세요.';
      });
      print('경로 재탐색 오류: $error');
      await _speakLowerPriorityAnnouncement(
        '경로 재탐색에 실패했습니다. 잠시 후 다시 시도합니다.',
      );
    } finally {
      _isRerouting = false;
    }
  }

  Future<void> _advanceNavigationStep() async {
    if (!_isNavigating) return;

    final int nextIndex = _currentNavigationStepIndex + 1;

    if (nextIndex >= _navigationSteps.length) {
      await _completeNavigation();
      return;
    }

    _currentNavigationStepIndex = nextIndex;
    _previousRouteProgressPosition = null;
    _reverseDirectionConsecutiveCount = 0;
    _lastReverseDirectionAnnouncementAt = null;

    final KakaoNavigationStep nextStep = _navigationSteps[nextIndex];
    _lastDistanceAnnouncementBucket =
        _distanceAnnouncementBucket(nextStep.distance);
    final String nextDirection = _turnInstructionAtStep(nextIndex);
    final String nextFullGuide =
        '여기서 ${_withoutFinalPeriod(nextDirection)}. '
        '이후 약 ${nextStep.distance}미터 이동하세요.';
    final String nextUpcomingGuide = _upcomingGuideForStep(
      nextIndex,
      nextStep.distance,
    );

    if (!mounted) return;
    setState(() {
      _navigationGuide = nextFullGuide;
      _upcomingNavigationGuide = nextUpcomingGuide;
      _navigationDistanceText =
          nextStep.distance > 0 ? '${nextStep.distance}m' : '-';
    });
    _lastDirectionAnnouncementKey = nextDirection;
    _lastDirectionAnnouncementAt = DateTime.now();
    await _sendNavigationMotorCommand(
      _turnNavigationMotorActionAtStep(nextIndex),
      force: true,
    );
    await _speakLowerPriorityAnnouncement(nextFullGuide);
  }

  Future<void> _completeNavigation() async {
    if (!_isNavigating) return;

    _isNavigating = false;
    _isNavigationPaused = false;
    _isRerouting = false;
    _previousRouteProgressPosition = null;
    _reverseDirectionConsecutiveCount = 0;
    _lastReverseDirectionAnnouncementAt = null;
    _previousNavigationPosition = null;
    _latestNavigationPosition = null;
    _currentTravelHeading = null;
    _lastCompassGuidanceAt = null;
    await _navigationPositionSubscription?.cancel();
    _navigationPositionSubscription = null;
    await _sendNavigationMotorCommand('STOP', force: true);

    if (!mounted) return;
    setState(() {
      _selectedTabIndex = 0;
      _navigationGuide = '목적지에 도착했습니다.';
      _upcomingNavigationGuide = '길안내가 자동으로 종료되었습니다.';
      _navigationDistanceText = '도착';
      _statusTitle = '목적지 도착';
      _statusSubtitle = '$_routeDestinationName에 도착했습니다.';
    });
    await _speakLowerPriorityAnnouncement(
      '목적지, $_routeDestinationName 주변에 도착했습니다. '
      '안전을 위해 출입구와 주변 장애물을 확인하세요.',
      holdDuringHazard: true,
    );
  }

  /// GPT destination에 남아 있을 수 있는 "근처/가까운/주변"과 조사를 떼어 카카오 검색어로 만든다.
  String _cleanDestinationKeyword(String destination) {
    String keyword = destination.trim();
    if (keyword.isEmpty) return '';
    for (final String word in <String>['근처', '가까운', '주변', '가장']) {
      keyword = keyword.replaceAll(word, ' ');
    }
    // 한 글자 조사("로", "에")는 "종로", "구로"처럼 지명 끝 글자일 수 있어 떼지 않는다.
    keyword = keyword.replaceAll(RegExp(r'(으로|까지|에서)$'), '');
    return keyword.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _extractDestinationKeyword(String text) {
    String keyword = text.trim();

    final List<String> removeWords = [
      '근처',
      '가까운',
      '주변',
      '으로',
      '로',
      '까지',
      '안내해줘',
      '안내해 줘',
      '안내',
      '길찾기',
      '길 찾아줘',
      '찾아줘',
      '찾아 줘',
      '가고 싶어',
      '가자',
      '어디야',
      '어디',
      '알려줘',
      '데려다줘',
      '데려다 줘',
    ];

    for (final String word in removeWords) {
      keyword = keyword.replaceAll(word, ' ');
    }

    keyword = keyword.replaceAll(RegExp(r'\s+'), ' ').trim();

    if (text.contains('편의점')) return '편의점';
    if (text.contains('카페')) return '카페';
    if (text.contains('병원')) return '병원';
    if (text.contains('약국')) return '약국';
    if (text.contains('은행')) return '은행';
    if (text.contains('학교')) return '학교';
    if (text.contains('지하철')) return '지하철역';
    if (text.contains('버스')) return '버스정류장';
    if (text.contains('화장실')) return '화장실';
    if (text.contains('식당')) return '식당';
    if (text.contains('음식점')) return '음식점';

    return keyword;
  }

  Future<Position> _getCurrentPosition() async {
    final bool serviceEnabled = await Geolocator.isLocationServiceEnabled();

    if (!serviceEnabled) {
      throw Exception('위치 서비스가 꺼져 있습니다.');
    }

    LocationPermission permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied) {
      throw Exception('위치 권한이 거부되었습니다.');
    }

    if (permission == LocationPermission.deniedForever) {
      throw Exception('위치 권한이 영구적으로 거부되었습니다. 앱 설정에서 위치 권한을 허용하세요.');
    }

    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    );
  }

  /// 현재 위치 20km 안에서 가장 가까운 곳을 먼저 찾고(20000은 카카오가 허용하는
  /// 최대 반경), 없으면 반경 없이 다시 찾는다. 그래서 멀리 있는 곳도 찾히며,
  /// 도보 안내가 가능한 거리인지는 호출한 쪽이 거리를 보고 판단한다.
  Future<KakaoPlace> _searchKakaoPlace({
    required String keyword,
    required double longitude,
    required double latitude,
  }) async {
    KakaoPlace? place = await _requestKakaoPlace(
      keyword: keyword,
      longitude: longitude,
      latitude: latitude,
      radiusMeters: 20000,
    );

    if (place == null) {
      print('[NAV] "$keyword" 20km 안에 없음 → 반경 없이 다시 검색');
      place = await _requestKakaoPlace(
        keyword: keyword,
        longitude: longitude,
        latitude: latitude,
      );
    }

    if (place == null) {
      throw NavigationFailure(
        '$keyword 검색 결과가 없습니다. 다른 이름으로 다시 말씀해 주세요.',
        detail: '$keyword 검색 결과가 없습니다.',
      );
    }

    return place;
  }

  /// 카카오 키워드 검색 1회. [radiusMeters]가 null이면 반경 제한 없이 가까운 순으로 찾는다.
  /// 결과가 없으면 null.
  Future<KakaoPlace?> _requestKakaoPlace({
    required String keyword,
    required double longitude,
    required double latitude,
    int? radiusMeters,
  }) async {
    final Map<String, String> query = <String, String>{
      'query': keyword,
      'x': longitude.toString(),
      'y': latitude.toString(),
      'sort': 'distance',
      'size': '1',
    };
    if (radiusMeters != null) {
      query['radius'] = radiusMeters.toString();
    }

    final Uri url = Uri.https(
      'dapi.kakao.com',
      '/v2/local/search/keyword.json',
      query,
    );

    final http.Response response = await http.get(
      url,
      headers: {
        'Authorization': 'KakaoAK $_kakaoRestApiKey',
      },
    );

    print('카카오 장소 검색 상태 코드: ${response.statusCode}');
    print('카카오 장소 검색 응답: ${response.body}');

    if (response.statusCode != 200) {
      throw NavigationFailure(
        '장소 검색에 실패했습니다. 네트워크 상태를 확인해 주세요.',
        detail: '장소 검색 실패: ${response.statusCode}\n${response.body}',
      );
    }

    final Map<String, dynamic> data = jsonDecode(response.body);
    final dynamic documents = data['documents'];

    if (documents is! List || documents.isEmpty) {
      return null;
    }

    final Map<String, dynamic> first =
        Map<String, dynamic>.from(documents.first as Map);

    return KakaoPlace.fromJson(first);
  }

  Future<KakaoWalkRoute> _getKakaoWalkRoute({
    required double startX,
    required double startY,
    required double endX,
    required double endY,
    required String endName,
  }) async {
    final Uri url = Uri.https(
      'dapi.kakao.com',
      '/v2/routing/walk',
      {
        'start_x': startX.toString(),
        'start_y': startY.toString(),
        'end_x': endX.toString(),
        'end_y': endY.toString(),
        's_name': '현재 위치',
        'e_name': endName,
        'input_coord': 'WGS84',
        'output_coord': 'WGS84',
        'route_mode': 'ACCESSIBLE',
      },
    );

    final http.Response response = await http.get(
      url,
      headers: {
        'Authorization': 'KakaoAK $_kakaoRestApiKey',
      },
    );

    print('카카오 도보 경로 상태 코드: ${response.statusCode}');
    print('카카오 도보 경로 응답: ${response.body}');

    if (response.statusCode != 200) {
      throw NavigationFailure(
        '경로를 찾지 못했습니다. 네트워크 상태를 확인해 주세요.',
        detail: '도보 경로 검색 실패: ${response.statusCode}\n${response.body}',
      );
    }

    final Map<String, dynamic> data = jsonDecode(response.body);
    final String status = data['status']?.toString() ?? '';

    // 카카오 도보 경로는 직선거리 약 30~35km를 넘으면 HTTP 200에
    // status TOO_FAR_AWAY와 빈 경로를 돌려준다 (2026-10-02 실측).
    if (status == 'TOO_FAR_AWAY') {
      final double straight = Geolocator.distanceBetween(
        startY,
        startX,
        endY,
        endX,
      );
      throw NavigationFailure(
        '$endName은 여기서 약 ${_formatKilometers(straight)} 떨어져 있어 '
        '도보로 안내할 수 없습니다.',
        detail: '카카오 도보 경로 TOO_FAR_AWAY (직선 ${straight.round()}m)',
      );
    }

    if (status != 'OK' || data['route'] == null) {
      throw NavigationFailure(
        '경로를 찾지 못했습니다.',
        detail: '도보 경로를 찾을 수 없습니다.\n${response.body}',
      );
    }

    return KakaoWalkRoute.fromJson(data);
  }

  String _formatSeconds(int seconds) {
    final int minutes = (seconds / 60).round();

    if (minutes < 60) {
      return '$minutes분';
    }

    final int hour = minutes ~/ 60;
    final int minute = minutes % 60;

    return '$hour시간 $minute분';
  }

  /// 음성용 거리 표기. 10km 미만은 소수 한 자리("7.5킬로미터"), 그 이상은 정수.
  String _formatKilometers(double meters) {
    final double km = meters / 1000;
    if (km < 10) return '${km.toStringAsFixed(1)}킬로미터';
    return '${km.round()}킬로미터';
  }

  // GPT가 target을 비워 보냈을 때 targetLabel과 원문에서 한국어 이름으로
  // YOLO 클래스를 찾는 보조 사전. 긴 이름부터 비교하므로 "와인잔"이 "잔"보다 먼저 맞는다.
  // 한 글자 이름(개, 차, 병 등)은 다른 단어와 오인될 수 있어 넣지 않는다.
  static const Map<String, String> _koreanYoloAliases = {
    '물병': 'bottle', '유리병': 'bottle', '페트병': 'bottle', '생수': 'bottle',
    '휴대폰': 'cell phone', '핸드폰': 'cell phone', '스마트폰': 'cell phone',
    '전화기': 'cell phone', '아이폰': 'cell phone', '갤럭시': 'cell phone',
    '리모컨': 'remote', '리모콘': 'remote',
    '노트북': 'laptop', '랩탑': 'laptop',
    '키보드': 'keyboard', '마우스': 'mouse',
    '텔레비전': 'tv', '티비': 'tv', '모니터': 'tv',
    '컵': 'cup', '머그컵': 'cup', '텀블러': 'cup',
    '와인잔': 'wine glass', '와인글라스': 'wine glass',
    '숟가락': 'spoon', '포크': 'fork', '나이프': 'knife', '그릇': 'bowl',
    '의자': 'chair', '소파': 'couch', '쇼파': 'couch', '침대': 'bed',
    '식탁': 'dining table', '테이블': 'dining table', '책상': 'dining table',
    '변기': 'toilet', '화장실': 'toilet',
    '책': 'book', '시계': 'clock', '꽃병': 'vase', '화분': 'potted plant',
    '가위': 'scissors', '칫솔': 'toothbrush', '드라이기': 'hair drier',
    '헤어드라이어': 'hair drier', '곰인형': 'teddy bear', '테디베어': 'teddy bear',
    '냉장고': 'refrigerator', '전자레인지': 'microwave', '오븐': 'oven',
    '토스터': 'toaster', '싱크대': 'sink', '세면대': 'sink',
    '배낭': 'backpack', '가방': 'backpack', '백팩': 'backpack',
    '핸드백': 'handbag', '여행가방': 'suitcase', '캐리어': 'suitcase',
    '우산': 'umbrella', '넥타이': 'tie',
    '사람': 'person', '강아지': 'dog', '고양이': 'cat', '새': 'bird',
    '자전거': 'bicycle', '자동차': 'car', '승용차': 'car', '오토바이': 'motorcycle',
    '버스': 'bus', '트럭': 'truck', '기차': 'train', '비행기': 'airplane',
    '보트': 'boat', '신호등': 'traffic light', '소화전': 'fire hydrant',
    '정지표지판': 'stop sign', '벤치': 'bench',
    '축구공': 'sports ball', '농구공': 'sports ball', '야구공': 'sports ball',
    '사과': 'apple', '바나나': 'banana', '오렌지': 'orange', '귤': 'orange',
    '샌드위치': 'sandwich', '피자': 'pizza', '도넛': 'donut', '케이크': 'cake',
    '브로콜리': 'broccoli', '당근': 'carrot', '핫도그': 'hot dog',
  };

  /// GPT가 돌려준 target을 우선 사용하고, 비어 있거나 목록에 없으면
  /// targetLabel과 음성 원문에서 한국어 별칭으로 YOLO 클래스를 찾는다.
  String? _resolveYoloTarget(IntentAnalysisResult result, String rawText) {
    final String? direct = _findSupportedYoloClass(result.target);
    if (direct != null) return direct;

    final String haystack =
        '${result.targetLabel} $rawText'.replaceAll(RegExp(r'\s+'), '');
    if (haystack.isEmpty) return null;

    final List<MapEntry<String, String>> entries =
        _koreanYoloAliases.entries.toList()
          ..sort((a, b) => b.key.length.compareTo(a.key.length));

    for (final MapEntry<String, String> entry in entries) {
      if (!haystack.contains(entry.key)) continue;
      final String? supported = _findSupportedYoloClass(entry.value);
      if (supported != null) {
        print('[INTENT] alias fallback: ${entry.key} -> $supported');
        return supported;
      }
    }
    return null;
  }

  String? _findSupportedYoloClass(String requestedTarget) {
    final String normalizedTarget = requestedTarget.trim().toLowerCase();
    if (normalizedTarget.isEmpty) return null;

    for (final String className in _yoloClasses) {
      if (className.toLowerCase() == normalizedTarget) {
        return className;
      }
    }

    return null;
  }

  Future<void> _stopObjectSearchSilently({bool clearDisplay = false}) async {
    if (_isBleConnected && _bleCharacteristic != null) {
      try {
        await _writeBleTextQueued('STOP');
        print('[APP -> PI] STOP (object search reset)');
      } catch (error) {
        print('객체 탐색 정지 오류: $error');
      }
    }

    _activeObjectTarget = '';
    _activeObjectLabel = '';
    _activeObjectMotorDirection = '';
    _objectMotorVisualTimer?.cancel();
    _lastObjectAnnouncementAt = null;
    _lastObjectAnnouncementKey = '';
    _pendingObjectAnnouncement = null;
    _pendingObjectAnnouncementAt = null;

    if (clearDisplay && mounted) {
      setState(() {
        _lastObjectDisplayTitle = '';
        _lastObjectDisplaySubtitle = '';
      });
    }
  }

  Future<void> _sendStopCommandByBle({bool foundByUser = false}) async {
    if (!_isBleConnected || _bleCharacteristic == null) {
      _showMessage('먼저 SmartCane을 BLE로 연결해주세요.');
      return;
    }

    final String label = _currentObjectLabel();

    await _sendBleCommand(
      command: 'STOP',
      sendingTitle: '기능 정지 중',
      completedTitle: label.isEmpty ? '기능 정지 완료' : '$label 찾기 종료',
      completedSubtitle: label.isEmpty
          ? '진행 중인 물건 찾기가 없습니다.'
          : (foundByUser
              ? '$label을 찾았습니다. 물건 찾기를 마쳤습니다.'
              : '$label 찾기를 멈췄습니다.'),
    );

    _activeObjectTarget = '';
    _activeObjectLabel = '';
    _activeObjectMotorDirection = '';
    _objectMotorVisualTimer?.cancel();
    _pendingObjectAnnouncement = null;
    _pendingObjectAnnouncementAt = null;

    // 물건 찾기 때문에 멈춰 둔 길안내가 있으면 이어간다. (안내 문구는 재개 쪽에서 읽는다)
    if (_isNavigationPaused) {
      await _resumeNavigationAfterObjectSearch(
        leadText: foundByUser && label.isNotEmpty ? '$label을 찾았습니다.' : null,
      );
      return;
    }

    // 전에는 화면 알림만 있고 음성이 없어서 "그만"이 먹었는지 알 수 없었다.
    final String announcement = label.isEmpty
        ? '진행 중인 물건 찾기가 없습니다.'
        : (foundByUser ? '$label 찾기를 마쳤습니다.' : '$label 찾기를 멈췄습니다.');
    _recordAppLog('object', announcement);
    await _speakLowerPriorityAnnouncement(announcement, holdDuringHazard: true);
  }

  Future<void> _sendObjectSearchByBle(
    String target,
    String targetLabel, {
    int? commandEpoch,
  }) async {
    if (commandEpoch != null && commandEpoch != _commandEpoch) return;
    final String? supportedTarget = _findSupportedYoloClass(target);
    if (supportedTarget == null) {
      _showMessage('현재 YOLO 모델에서 지원하지 않는 객체입니다.');
      return;
    }

    if (!_isBleConnected || _bleCharacteristic == null) {
      _showMessage('먼저 SmartCane을 BLE로 연결해주세요.');
      return;
    }

    if (_activeObjectTarget.isNotEmpty &&
        _activeObjectTarget.toLowerCase() != supportedTarget.toLowerCase()) {
      await _stopObjectSearchSilently(clearDisplay: true);
      if (commandEpoch != null && commandEpoch != _commandEpoch) return;
    }

    _activeObjectTarget = supportedTarget;
    _activeObjectLabel = targetLabel.trim().isEmpty
        ? supportedTarget
        : targetLabel.trim();

    await _sendBleCommand(
      command: 'FIND:$supportedTarget',
      sendingTitle: '물건 찾기 준비 중',
      completedTitle: '물건 찾는 중',
      completedSubtitle: '지팡이를 천천히 움직이며 물건을 찾아보세요.',
    );

    // 전송 도중 초기화/새 명령이 들어왔다면 늦게 전송된 FIND를 다시 정지한다.
    if (commandEpoch != null && commandEpoch != _commandEpoch) {
      await _stopObjectSearchSilently(clearDisplay: true);
    }
  }

  Future<void> _sendBleCommand({
    required String command,
    required String sendingTitle,
    required String completedTitle,
    required String completedSubtitle,
  }) async {
    try {
      setState(() {
        _statusTitle = sendingTitle;
        _statusSubtitle = 'SmartCane으로 명령을 전송하고 있습니다.';
      });

      print('[APP -> PI] $command');
      await _writeBleTextQueued(command);

      if (!mounted) return;
      setState(() {
        _statusTitle = completedTitle;
        _statusSubtitle = completedSubtitle;
      });

      _showMessage(completedTitle);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusTitle = 'BLE 전송 실패';
        _statusSubtitle = e.toString();
      });
      print('BLE send error: $e');
      _showMessage('BLE 전송 실패: $e');
    }
  }

  Future<void> _clearAll() async {
    // 상시 안전 기능의 현재 위험 표시는 사용자 명령 초기화와 별개다.
    final bool hazardWasActive = _hazardDisplayActive;
    final String hazardTitleBeforeClear = _statusTitle;
    final String hazardSubtitleBeforeClear = _statusSubtitle;

    // 진행 중인 GPT 의도 분석/길찾기 작업의 늦은 결과를 모두 무효화한다.
    _commandEpoch += 1;

    // stop()의 done 콜백이 자동 분석을 다시 시작하지 않도록 먼저 상태를 잠근다.
    _isListening = false;
    _autoAnalyzeStarted = true;

    if (_speech.isListening) {
      try {
        await _speech.stop();
      } catch (error) {
        print('초기화 중 STT 종료 오류: $error');
      }
    }

    await _stopObjectSearchSilently(clearDisplay: false);
    await _stopNavigation(resetGuide: true);
    await _clearRouteOnKakaoMap();

    if (!mounted) return;

    setState(() {
      _selectedTabIndex = 0;
      _recognizedText = '';
      _analysisResult = IntentAnalysisResult.empty();
      _statusTitle =
          hazardWasActive ? hazardTitleBeforeClear : '초기화 완료';
      _statusSubtitle = hazardWasActive
          ? hazardSubtitleBeforeClear
          : '마이크 버튼을 눌러 다시 시작하세요.';
      _isListening = false;
      _isAnalyzing = false;
      _isFindingRoute = false;
      _autoAnalyzeStarted = false;

      _activeObjectTarget = '';
      _activeObjectLabel = '';
      _lastObjectAnnouncementAt = null;
      _lastObjectAnnouncementKey = '';
      _lastObjectDisplayTitle = '';
      _lastObjectDisplaySubtitle = '';

      // 위험 상태/TTS 주기는 상시 안전 기능이므로 초기화하지 않는다.
      _pendingImportantTts = '';

      _routeDestinationName = '-';
      _routeSummary = '-';
      _routeFirstGuide = '-';
    });

    _showMessage('초기화되었습니다.');
  }

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // 위험 감지 중에는 빨간 배너가 위험 문구를 보여주므로, 상태 카드에는
  // 같은 문구를 반복하지 않고 앱이 하고 있는 동작을 보여준다.
  String _userFacingStatusTitle() {
    if (_isListening) return '듣고 있어요';
    if (_isFindingRoute) return '경로를 찾고 있어요';
    if (_isAnalyzing) return '요청을 분석하고 있어요';
    if (_isNavigationPaused) return '물건을 찾고 있어요 · 길안내 잠시 멈춤';
    if (_isNavigating) return '길안내 중';
    if (_activeObjectTarget.trim().isNotEmpty) return '물건을 찾고 있어요';
    if (_hazardDisplayActive) {
      return _lastObjectDisplayTitle.isNotEmpty
          ? _lastObjectDisplayTitle
          : '음성 인식 준비 완료';
    }
    return _statusTitle;
  }

  String _userFacingStatusSubtitle() {
    if (_isListening) return '말씀하신 내용을 듣고 있습니다.';
    if (_isFindingRoute) return '목적지까지의 보행 경로를 확인하고 있습니다.';
    if (_isAnalyzing) return '음성 명령의 의미를 확인하고 있습니다.';
    if (_isNavigationPaused) {
      final String label = _activeObjectLabel.trim().isEmpty
          ? _activeObjectTarget
          : _activeObjectLabel;
      return '$label을 찾는 중입니다. "그만"이라고 말하면 '
          '$_routeDestinationName 길안내를 이어갑니다.';
    }
    if (_isNavigating) return _navigationGuide;
    if (_activeObjectTarget.trim().isNotEmpty) {
      final String label = _activeObjectLabel.trim().isEmpty
          ? _activeObjectTarget
          : _activeObjectLabel;
      return '$label을 찾는 중입니다. 지팡이를 천천히 움직여 주세요.';
    }
    if (_hazardDisplayActive) {
      return _lastObjectDisplaySubtitle.isNotEmpty
          ? _lastObjectDisplaySubtitle
          : '마이크에 대고 말씀해주세요.';
    }
    return _statusSubtitle;
  }

  String _intentDisplayLabel(String intent) {
    switch (intent.trim().toLowerCase()) {
      case 'find_object':
        return '물건 찾기 · find_object';
      case 'navigate':
        return '길안내 · navigate';
      case 'stop':
        return '기능 중지 · stop';
      case 'status':
        return '상태 확인 · status';
      case 'where_am_i':
        return '현재 위치 · where_am_i';
      case 'repeat':
        return '다시 듣기 · repeat';
      case 'save_place':
        return '장소 저장 · save_place';
      case 'delete_place':
        return '장소 삭제 · delete_place';
      case 'connect':
        return '지팡이 연결 · connect';
      case 'disconnect':
        return '지팡이 연결 해제 · disconnect';
      case 'unknown':
        return '기타 명령 · unknown';
      case '-':
        return '-';
      default:
        return intent.trim().isEmpty ? '-' : intent;
    }
  }

  Color _statusAccentColor() {
    if (_isNavigating || _isFindingRoute) return const Color(0xFF155EEF);
    if (_activeObjectTarget.trim().isNotEmpty) return const Color(0xFF0F7B6C);
    return const Color(0xFF155EEF);
  }

  IconData _statusIcon() {
    if (_isListening) return Icons.graphic_eq_rounded;
    if (_isNavigating || _isFindingRoute) return Icons.navigation_rounded;
    if (_activeObjectTarget.trim().isNotEmpty) return Icons.search_rounded;
    return Icons.check_circle_outline_rounded;
  }

  Widget _surface({
    required Widget child,
    EdgeInsets padding = const EdgeInsets.all(20),
  }) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: const Color(0xFFE2E5EA),
          width: 1,
        ),
      ),
      child: child,
    );
  }

  Widget _sectionTitle({
    required String number,
    required String title,
    IconData? icon,
  }) {
    return Row(
      children: [
        Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFF155EEF),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(
            number,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(width: 10),
        if (icon != null) ...[
          Icon(icon, size: 22, color: const Color(0xFF155EEF)),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w800,
              color: Color(0xFF16181D),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final MediaQueryData mediaQuery = MediaQuery.of(context);
    // 큰 글씨 옵션: 시스템 글자 크기에 1.3배를 더 곱한다.
    final TextScaler textScaler = _largeTextEnabled
        ? TextScaler.linear(mediaQuery.textScaler.scale(1.0) * 1.3)
        : mediaQuery.textScaler;

    return MediaQuery(
      data: mediaQuery.copyWith(textScaler: textScaler),
      child: _buildScaffold(),
    );
  }

  Widget _buildScaffold() {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: IndexedStack(
                index: _selectedTabIndex,
                children: [
                  _buildHomeTab(),
                  _buildNavigationTab(),
                  _buildSettingsTab(),
                ],
              ),
            ),
            _buildBottomNavigation(),
          ],
        ),
      ),
    );
  }

  Widget _buildHomeTab() {
    return SingleChildScrollView(
      key: const PageStorageKey<String>('home-tab'),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHomeHeader(),
          if (_hazardDisplayActive) ...[
            const SizedBox(height: 14),
            _buildHazardBanner(),
          ],
          const SizedBox(height: 22),
          _buildVoiceHero(),
          const SizedBox(height: 16),
          _buildCurrentStatusPanel(),
          if (!_simpleModeEnabled &&
              _activeObjectTarget.trim().isNotEmpty) ...[
            const SizedBox(height: 14),
            _buildObjectMotorVisualizer(),
          ],
          // 심사용 카드: 간단 모드에서는 숨긴다.
          if (!_simpleModeEnabled) ...[
            const SizedBox(height: 20),
            _buildRecognizedVoiceCard(),
            const SizedBox(height: 14),
            _buildResultCard(),
            const SizedBox(height: 14),
            _buildActionButtons(),
          ],
          const SizedBox(height: 18),
          _buildDeviceSummary(),
          if (!_simpleModeEnabled) ...[
            const SizedBox(height: 14),
            _buildBleLogCard(),
          ],
        ],
      ),
    );
  }

  Widget _buildHomeHeader() {
    return Row(
      children: [
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'SmartCane',
                style: TextStyle(
                  fontSize: 27,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.5,
                  color: Color(0xFF16181D),
                ),
              ),
              SizedBox(height: 3),
              Text(
                'AI 기반 보행 보조 서비스',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF747A84),
                ),
              ),
            ],
          ),
        ),
        // TalkBack: "연결됨"이 아니라 "지팡이 연결됨, 버튼, 설정 열기"로 읽히게 한다.
        MergeSemantics(
          child: Semantics(
            button: true,
            label: _isBleConnected ? '지팡이 연결됨' : '지팡이 연결 안 됨',
            hint: '설정 탭 열기',
            excludeSemantics: true,
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => setState(() => _selectedTabIndex = 2),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: BoxDecoration(
                  color: _isBleConnected
                      ? const Color(0xFFECF8F2)
                      : const Color(0xFFF2F3F5),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: _isBleConnected
                            ? const Color(0xFF1D9B62)
                            : const Color(0xFF7A8089),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      _isBleConnected ? '연결됨' : '연결 안 됨',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: _isBleConnected
                            ? const Color(0xFF167A4D)
                            : const Color(0xFF6F747D),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHazardBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF1F1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFF1BBBB)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            size: 30,
            color: Color(0xFFC83B3B),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _statusTitle,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF9E2929),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _statusSubtitle,
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF7F3B3B),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVoiceHero() {
    final bool disabled = _isAnalyzing || _isFindingRoute;
    final Color buttonColor = disabled
        ? const Color(0xFFAEB3BC)
        : (_isListening
            ? const Color(0xFFB42318)
            : const Color(0xFF155EEF));

    return _surface(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 22),
      child: Column(
        children: [
          const Text(
            '무엇을 도와드릴까요?',
            style: TextStyle(
              fontSize: 23,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.3,
              color: Color(0xFF16181D),
            ),
          ),
          const SizedBox(height: 7),
          const Text(
            '물건 찾기나 목적지 길안내를 음성으로 요청하세요.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              height: 1.45,
              fontWeight: FontWeight.w600,
              color: Color(0xFF707681),
            ),
          ),
          const SizedBox(height: 18),
          // 화면 폭 전체를 쓰는 큰 음성 버튼. 손으로 더듬어도 찾기 쉽고 한 번에 눌린다.
          Semantics(
            button: true,
            label: _isListening ? '음성 인식 종료' : '음성 인식 시작',
            child: Material(
              color: buttonColor,
              borderRadius: BorderRadius.circular(22),
              elevation: disabled ? 0 : 4,
              shadowColor: buttonColor.withValues(alpha: 0.35),
              child: InkWell(
                borderRadius: BorderRadius.circular(22),
                onTap: disabled ? null : _handleVoiceButton,
                child: SizedBox(
                  width: double.infinity,
                  height: 128,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Icon(
                        _isListening ? Icons.stop_rounded : Icons.mic_rounded,
                        size: 54,
                        color: Colors.white,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _isListening ? '듣기 종료' : '눌러서 말하기',
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            _isListening
                ? '말씀이 끝나면 자동으로 분석합니다.'
                : '볼륨 UP 버튼을 길게 눌러도 시작할 수 있습니다.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Color(0xFF6B717B),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCurrentStatusPanel() {
    final Color accent = _statusAccentColor();

    return _surface(
      padding: const EdgeInsets.all(17),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(_statusIcon(), color: accent, size: 25),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '현재 상태',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF7B8089),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _userFacingStatusTitle(),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF1A1C21),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _userFacingStatusSubtitle(),
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF666C76),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecognizedVoiceCard() {
    final String displayText = _recognizedText.trim().isEmpty
        ? '아직 인식된 음성이 없습니다.'
        : _recognizedText;

    return _surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(
            number: '1',
            title: '인식된 음성',
            icon: Icons.mic_none_rounded,
          ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
            decoration: BoxDecoration(
              color: const Color(0xFFF7F8FA),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Text(
              _recognizedText.trim().isEmpty
                  ? displayText
                  : '“$displayText”',
              style: TextStyle(
                fontSize: 17,
                height: 1.4,
                fontWeight: FontWeight.w700,
                color: _recognizedText.trim().isEmpty
                    ? const Color(0xFF7A8089)
                    : const Color(0xFF202329),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultCard() {
    return _surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(
            number: '2',
            title: 'GPT 의도 분석 결과',
            icon: Icons.auto_awesome_outlined,
          ),
          const SizedBox(height: 16),
          if (_isAnalyzing)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 22),
              child: Center(
                child: Column(
                  children: [
                    CircularProgressIndicator(strokeWidth: 3),
                    SizedBox(height: 12),
                    Text(
                      '음성 명령을 분석하고 있습니다.',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF666C76),
                      ),
                    ),
                  ],
                ),
              ),
            )
          else ...[
            _buildAnalysisRow(
              label: '의도',
              value: _intentDisplayLabel(_analysisResult.intent),
            ),
            const Divider(height: 22, color: Color(0xFFE8EAEE)),
            _buildAnalysisRow(
              label: '핵심 내용',
              value: _analysisResult.coreContent,
            ),
            const Divider(height: 22, color: Color(0xFFE8EAEE)),
            _buildAnalysisRow(
              label: '앱 동작',
              value: _analysisResult.appAction,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAnalysisRow({
    required String label,
    required String value,
  }) {
    final String displayValue = value.trim().isEmpty ? '-' : value;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 76,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: Color(0xFF6D727C),
            ),
          ),
        ),
        Expanded(
          child: Text(
            displayValue,
            style: const TextStyle(
              fontSize: 14,
              height: 1.45,
              fontWeight: FontWeight.w700,
              color: Color(0xFF202329),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildActionButtons() {
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 48,
            child: OutlinedButton.icon(
              onPressed: (_isAnalyzing || _isFindingRoute)
                  ? null
                  : _analyzeIntent,
              icon: const Icon(Icons.refresh_rounded, size: 20),
              label: const Text(
                '다시 분석',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF155EEF),
                side: const BorderSide(color: Color(0xFFD3D7DE)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(13),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: SizedBox(
            height: 48,
            child: OutlinedButton.icon(
              onPressed: _clearAll,
              icon: const Icon(Icons.restart_alt_rounded, size: 20),
              label: const Text(
                '초기화',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF555B65),
                side: const BorderSide(color: Color(0xFFD3D7DE)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(13),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDeviceSummary() {
    final String batteryText =
        _piBattery == null ? '수신 대기' : '${_piBattery!.toStringAsFixed(0)}%';

    // TalkBack: 카드 전체가 설정으로 가는 버튼임을 알린다.
    return MergeSemantics(
      child: Semantics(
        button: true,
        hint: '설정 탭 열기',
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => setState(() => _selectedTabIndex = 2),
          child: _surface(
            padding: const EdgeInsets.all(17),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0F3F7),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.assist_walker_rounded,
                    color: Color(0xFF4F5661),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'SmartCane',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF202329),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _isBleConnected ? '연결됨 · 배터리 $batteryText' : '연결 안 됨',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF747A84),
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: Color(0xFF969BA4),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavigationTab() {
    return SingleChildScrollView(
      key: const PageStorageKey<String>('navigation-tab'),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildNavigationHeader(),
          if (_hazardDisplayActive) ...[
            const SizedBox(height: 14),
            _buildHazardBanner(),
          ],
          const SizedBox(height: 18),
          _buildNavigationGuideCard(),
          const SizedBox(height: 14),
          _buildSavedPlacesCard(),
          if (_routePoints.length >= 2) ...[
            const SizedBox(height: 14),
            _buildMapCard(),
          ],
          if (!_simpleModeEnabled) ...[
            const SizedBox(height: 14),
            _buildRouteResultCard(),
          ],
          const SizedBox(height: 14),
          _buildNavigationVoiceControl(),
        ],
      ),
    );
  }

  Widget _buildSavedPlacesCard() {
    const Color accent = Color(0xFF155EEF);
    const Color muted = Color(0xFF747A84);
    final bool busy = _isSavingPlace || _isFindingRoute || _isAnalyzing;

    return _surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Expanded(
                child: Text(
                  '저장된 장소',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF202329),
                  ),
                ),
              ),
              if (_isSavingPlace)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 5),
          const Text(
            '“집으로 안내해줘”, “여기를 회사로 저장해줘”라고 말하거나 아래에서 바로 선택할 수 있습니다.',
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              fontWeight: FontWeight.w600,
              color: muted,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              Expanded(
                child: SizedBox(
                  height: 46,
                  child: FilledButton.tonalIcon(
                    onPressed: busy ? null : _promptSaveCurrentLocation,
                    icon: const Icon(Icons.my_location_rounded, size: 19),
                    label: const Text(
                      '현재 위치 저장',
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFEAF2FF),
                      foregroundColor: accent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(13),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: SizedBox(
                  height: 46,
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : _promptSearchAndSavePlace,
                    icon: const Icon(Icons.search_rounded, size: 19),
                    label: const Text(
                      '검색해서 저장',
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF555B65),
                      side: const BorderSide(color: Color(0xFFD3D7DE)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(13),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (_savedPlaces.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 14),
              decoration: BoxDecoration(
                color: const Color(0xFFF6F7F9),
                borderRadius: BorderRadius.circular(13),
              ),
              child: const Text(
                '아직 저장된 장소가 없습니다. 집이나 회사에서 “현재 위치 저장”을 눌러 보세요.',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                  color: muted,
                ),
              ),
            )
          else
            ..._savedPlaces.map(
              (SavedPlace place) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: const Color(0xFFF6F7F9),
                  borderRadius: BorderRadius.circular(13),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(13),
                    onTap: busy ? null : () => _navigateToSavedPlace(place),
                    onLongPress: () => _confirmDeleteSavedPlace(place),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
                      child: Row(
                        children: <Widget>[
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: const Color(0xFFEAF2FF),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(place.icon, color: accent),
                          ),
                          const SizedBox(width: 11),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  place.name,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w900,
                                    color: Color(0xFF202329),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  place.address,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 6),
                          // TalkBack: "안내"만 읽히지 않도록 장소 이름을 붙인다.
                          Semantics(
                            button: true,
                            enabled: !busy,
                            label: '${place.name}으로 안내',
                            onTap: busy ? null : () => _navigateToSavedPlace(place),
                            excludeSemantics: true,
                            child: FilledButton(
                              onPressed:
                                  busy ? null : () => _navigateToSavedPlace(place),
                              style: FilledButton.styleFrom(
                                backgroundColor: accent,
                                minimumSize: const Size(60, 40),
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(11),
                                ),
                              ),
                              child: const Text(
                                '안내',
                                style: TextStyle(fontWeight: FontWeight.w900),
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '${place.name} 삭제',
                            onPressed: () => _confirmDeleteSavedPlace(place),
                            icon: const Icon(
                              Icons.delete_outline_rounded,
                              color: Color(0xFF7A8089),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildNavigationHeader() {
    final String destination = _routeDestinationName == '-'
        ? '길안내'
        : _routeDestinationName;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '길안내',
                style: TextStyle(
                  fontSize: 27,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.5,
                  color: Color(0xFF16181D),
                ),
              ),
            ),
            if (_isNavigating)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: const Color(0xFFEAF2FF),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(
                  _isNavigationPaused ? '잠시 멈춤' : '안내 중',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF155EEF),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 13),
        _surface(
          padding: const EdgeInsets.all(17),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: const Color(0xFFEAF2FF),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: const Icon(
                  Icons.place_outlined,
                  color: Color(0xFF155EEF),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '목적지',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF7B8089),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      destination,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF202329),
                      ),
                    ),
                    if (_routeSummary != '-') ...[
                      const SizedBox(height: 3),
                      Text(
                        _routeSummary,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF747A84),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }


  Widget _buildNavigationGuideCard() {
    return _surface(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: const Color(0xFF155EEF),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: const Icon(
                  Icons.navigation_rounded,
                  color: Colors.white,
                  size: 29,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _isNavigating
                          ? '현재 안내 · $_navigationDistanceText'
                          : '현재 안내',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF155EEF),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _navigationGuide,
                      style: const TextStyle(
                        fontSize: 20,
                        height: 1.32,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF16181D),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_upcomingNavigationGuide.isNotEmpty) ...[
            const SizedBox(height: 15),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFF5F7FA),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _upcomingNavigationGuide,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF555B65),
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
            decoration: BoxDecoration(
              color: const Color(0xFFF7F9FC),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE4E8EF)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: const [
                    Icon(
                      Icons.vibration_rounded,
                      color: Color(0xFF155EEF),
                      size: 21,
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '현재 안내와 연결된 진동모터 표시',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF202329),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const SizedBox(height: 6),
                _buildNavigationMotorVisualizerInline(),
              ],
            ),
          ),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: _navigationGuide.trim().isEmpty
                ? null
                : () => unawaited(
                      _speakLowerPriorityAnnouncement(_navigationGuide),
                    ),
            icon: const Icon(Icons.volume_up_rounded, size: 20),
            label: const Text(
              '현재 안내 다시 듣기',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF155EEF),
              padding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );
  }

  void _scheduleObjectMotorVisualClear(String direction) {
    _objectMotorVisualTimer?.cancel();
    final String normalized = direction.trim().toUpperCase();
    if (normalized.isEmpty) return;

    // 실제 진동은 짧게 반복되므로, 발표/테스트 화면에서는 방향을
    // 알아보기 쉽도록 조금 더 길게 강조한다.
    _objectMotorVisualTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted || _activeObjectMotorDirection != normalized) return;
      setState(() {
        _activeObjectMotorDirection = '';
      });
    });
  }

  Widget _buildObjectMotorVisualizer() {
    final String direction = _activeObjectMotorDirection.trim().toUpperCase();
    final bool top = direction == 'TOP' ||
        direction == 'TOP+LEFT' ||
        direction == 'TOP+RIGHT' ||
        direction == 'CENTER';
    final bool left = direction == 'LEFT' ||
        direction == 'TOP+LEFT' ||
        direction == 'BOTTOM+LEFT' ||
        direction == 'CENTER';
    final bool right = direction == 'RIGHT' ||
        direction == 'TOP+RIGHT' ||
        direction == 'BOTTOM+RIGHT' ||
        direction == 'CENTER';
    final bool bottom = direction == 'BOTTOM' ||
        direction == 'BOTTOM+LEFT' ||
        direction == 'BOTTOM+RIGHT' ||
        direction == 'CENTER';
    final bool hasActiveMotor = top || left || right || bottom;

    String activeLabel;
    if (direction == 'CENTER') {
      activeLabel = '정면 중앙 · 4개 모터';
    } else if (direction == 'TOP+LEFT') {
      activeLabel = '왼쪽 위 · 위쪽 + 왼쪽 모터';
    } else if (direction == 'TOP+RIGHT') {
      activeLabel = '오른쪽 위 · 위쪽 + 오른쪽 모터';
    } else if (direction == 'BOTTOM+LEFT') {
      activeLabel = '왼쪽 아래 · 아래쪽 + 왼쪽 모터';
    } else if (direction == 'BOTTOM+RIGHT') {
      activeLabel = '오른쪽 아래 · 아래쪽 + 오른쪽 모터';
    } else if (direction == 'TOP') {
      activeLabel = '위쪽 모터';
    } else if (direction == 'LEFT') {
      activeLabel = '왼쪽 모터';
    } else if (direction == 'RIGHT') {
      activeLabel = '오른쪽 모터';
    } else if (direction == 'BOTTOM') {
      activeLabel = '아래쪽 모터';
    } else {
      activeLabel = '객체를 탐색하고 있습니다.';
    }

    final String targetLabel = _activeObjectLabel.trim().isNotEmpty
        ? _activeObjectLabel.trim()
        : _activeObjectTarget.trim();

    return _surface(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.search_rounded, color: Color(0xFF155EEF)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$targetLabel 객체 탐색 · 진동 위치',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF202329),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 13),
          _buildFourMotorDiagram(
            topActive: top,
            leftActive: left,
            rightActive: right,
            bottomActive: bottom,
          ),
          const SizedBox(height: 13),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: hasActiveMotor
                  ? const Color(0xFFEAF2FF)
                  : const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(
                  hasActiveMotor
                      ? Icons.vibration_rounded
                      : Icons.radar_rounded,
                  size: 20,
                  color: hasActiveMotor
                      ? const Color(0xFF155EEF)
                      : const Color(0xFF777D87),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    hasActiveMotor
                        ? '$activeLabel가 울리고 있습니다.'
                        : activeLabel,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                      color: hasActiveMotor
                          ? const Color(0xFF155EEF)
                          : const Color(0xFF666C76),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 7),
          const Text(
            '객체 위치에 따라 실제 지팡이의 4방향 진동모터 동작을 표시합니다.',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: Color(0xFF8A9099),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFourMotorDiagram({
    required bool topActive,
    required bool leftActive,
    required bool rightActive,
    required bool bottomActive,
  }) {
    return Container(
      width: double.infinity,
      height: 286,
      decoration: BoxDecoration(
        color: const Color(0xFFF7F9FC),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE4E8EF)),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            top: 55,
            bottom: 48,
            child: Column(
              children: [
                Container(
                  width: 34,
                  height: 58,
                  decoration: BoxDecoration(
                    color: const Color(0xFF30343B),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: const Color(0xFF1F2329),
                      width: 2,
                    ),
                  ),
                  child: const Icon(
                    Icons.sensors_rounded,
                    size: 18,
                    color: Colors.white70,
                  ),
                ),
                Container(
                  width: 10,
                  height: 105,
                  decoration: BoxDecoration(
                    color: const Color(0xFFECEFF3),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFFB9C0CA)),
                  ),
                ),
                Transform.rotate(
                  angle: -0.35,
                  child: Container(
                    width: 38,
                    height: 9,
                    decoration: BoxDecoration(
                      color: const Color(0xFFECEFF3),
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(color: const Color(0xFFB9C0CA)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            top: 14,
            child: _buildMotorIndicator(
              label: '위쪽',
              icon: Icons.keyboard_arrow_up_rounded,
              active: topActive,
            ),
          ),
          Positioned(
            left: 14,
            top: 112,
            child: _buildMotorIndicator(
              label: '왼쪽',
              icon: Icons.keyboard_arrow_left_rounded,
              active: leftActive,
            ),
          ),
          Positioned(
            right: 14,
            top: 112,
            child: _buildMotorIndicator(
              label: '오른쪽',
              icon: Icons.keyboard_arrow_right_rounded,
              active: rightActive,
            ),
          ),
          Positioned(
            bottom: 12,
            child: _buildMotorIndicator(
              label: '아래쪽',
              icon: Icons.keyboard_arrow_down_rounded,
              active: bottomActive,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavigationMotorVisualizerInline() {
    final String action = _activeNavigationMotorAction.trim().toUpperCase();
    final bool isForward = action == 'FORWARD';
    final bool isLeft = action == 'LEFT';
    final bool isRight = action == 'RIGHT';
    final bool isBack = action == 'UTURN';
    final bool hasActiveMotor = isForward || isLeft || isRight || isBack;

    String activeLabel;
    if (isForward) {
      activeLabel = '위쪽(직진) 모터';
    } else if (isLeft) {
      activeLabel = '왼쪽 모터';
    } else if (isRight) {
      activeLabel = '오른쪽 모터';
    } else if (isBack) {
      activeLabel = '아래쪽(뒤로) 모터';
    } else {
      activeLabel = '현재 울리는 모터 없음';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          height: 286,
          decoration: BoxDecoration(
            color: const Color(0xFFF7F9FC),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFFE4E8EF)),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned(
                top: 55,
                bottom: 48,
                child: Column(
                  children: [
                    Container(
                      width: 34,
                      height: 58,
                      decoration: BoxDecoration(
                        color: const Color(0xFF30343B),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: const Color(0xFF1F2329),
                          width: 2,
                        ),
                      ),
                      child: const Icon(
                        Icons.sensors_rounded,
                        size: 18,
                        color: Colors.white70,
                      ),
                    ),
                    Container(
                      width: 10,
                      height: 105,
                      decoration: BoxDecoration(
                        color: const Color(0xFFECEFF3),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFFB9C0CA)),
                      ),
                    ),
                    Transform.rotate(
                      angle: -0.35,
                      child: Container(
                        width: 38,
                        height: 9,
                        decoration: BoxDecoration(
                          color: const Color(0xFFECEFF3),
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(color: const Color(0xFFB9C0CA)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                top: 14,
                child: _buildMotorIndicator(
                  label: '위쪽',
                  icon: Icons.keyboard_arrow_up_rounded,
                  active: isForward,
                ),
              ),
              Positioned(
                left: 14,
                top: 112,
                child: _buildMotorIndicator(
                  label: '왼쪽',
                  icon: Icons.keyboard_arrow_left_rounded,
                  active: isLeft,
                ),
              ),
              Positioned(
                right: 14,
                top: 112,
                child: _buildMotorIndicator(
                  label: '오른쪽',
                  icon: Icons.keyboard_arrow_right_rounded,
                  active: isRight,
                ),
              ),
              Positioned(
                bottom: 12,
                child: _buildMotorIndicator(
                  label: '아래쪽',
                  icon: Icons.keyboard_arrow_down_rounded,
                  active: isBack,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 13),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: hasActiveMotor
                ? const Color(0xFFEAF2FF)
                : const Color(0xFFF3F4F6),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(
                hasActiveMotor
                    ? Icons.vibration_rounded
                    : Icons.do_not_disturb_on_outlined,
                size: 20,
                color: hasActiveMotor
                    ? const Color(0xFF155EEF)
                    : const Color(0xFF777D87),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  hasActiveMotor
                      ? '현재 안내에 따라 $activeLabel 가 울리고 있습니다.'
                      : activeLabel,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    color: hasActiveMotor
                        ? const Color(0xFF155EEF)
                        : const Color(0xFF666C76),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 7),
        Text(
          _navigationMotorStatus,
          style: const TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: Color(0xFF8A9099),
          ),
        ),
      ],
    );
  }

  Widget _buildMotorIndicator({
    required String label,
    required IconData icon,
    required bool active,
  }) {
    final Color foreground =
        active ? const Color(0xFF155EEF) : const Color(0xFF8A9099);
    final Color background =
        active ? const Color(0xFFDCE9FF) : Colors.white;

    return Semantics(
      label: '$label 진동모터 ${active ? '동작 중' : '대기'}',
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        width: 82,
        height: 72,
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: active ? const Color(0xFF155EEF) : const Color(0xFFD7DBE2),
            width: active ? 3 : 1.5,
          ),
          boxShadow: active
              ? const [
                  BoxShadow(
                    color: Color(0x33155EEF),
                    blurRadius: 15,
                    spreadRadius: 3,
                  ),
                ]
              : const [],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 28, color: foreground),
            Text(
              active ? '$label · 진동' : label,
              style: TextStyle(
                fontSize: active ? 12.5 : 12,
                fontWeight: active ? FontWeight.w900 : FontWeight.w700,
                color: foreground,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMapCard() {
    return _surface(
      padding: const EdgeInsets.all(10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(13),
        child: SizedBox(
          width: double.infinity,
          height: 330,
          child: Stack(
            children: [
              Positioned.fill(
                child: WebViewWidget(controller: _kakaoMapController),
              ),
              Positioned(
                right: 12,
                bottom: 12,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildMapControlButton(
                      icon: Icons.my_location_rounded,
                      tooltip: '현 위치',
                      onPressed: _moveKakaoMapToCurrentLocation,
                    ),
                    const SizedBox(height: 8),
                    _buildMapControlButton(
                      icon: Icons.route_rounded,
                      tooltip: '전체 경로',
                      onPressed: _showEntireKakaoRoute,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMapControlButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return Material(
      color: Colors.white,
      elevation: 3,
      shadowColor: Colors.black26,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onPressed,
          child: Semantics(
            button: true,
            label: tooltip,
            child: SizedBox(
              width: 46,
              height: 46,
              child: Icon(
                icon,
                size: 24,
                color: const Color(0xFF155EEF),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRouteResultCard() {
    return _surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(
            number: '3',
            title: '카카오맵 길찾기 결과',
            icon: Icons.map_outlined,
          ),
          const SizedBox(height: 16),
          if (_isFindingRoute)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(child: CircularProgressIndicator(strokeWidth: 3)),
            )
          else ...[
            _buildAnalysisRow(
              label: '목적지',
              value: _routeDestinationName,
            ),
            const Divider(height: 22, color: Color(0xFFE8EAEE)),
            _buildAnalysisRow(
              label: '경로 정보',
              value: _routeSummary,
            ),
            const Divider(height: 22, color: Color(0xFFE8EAEE)),
            _buildAnalysisRow(
              label: '첫 안내',
              value: _routeFirstGuide,
            ),
            if (_kakaoMapError.isNotEmpty) ...[
              const Divider(height: 22, color: Color(0xFFE8EAEE)),
              Text(
                '지도 오류: $_kakaoMapError',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFFB42318),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildNavigationVoiceControl() {
    return _surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '길안내 제어',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: Color(0xFF202329),
            ),
          ),
          const SizedBox(height: 5),
          const Text(
            '“길안내 취소”, “중지”, “멈춰”라고 말할 수 있습니다.',
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              fontWeight: FontWeight.w600,
              color: Color(0xFF747A84),
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: FilledButton.icon(
              onPressed: (_isAnalyzing || _isFindingRoute)
                  ? null
                  : _handleVoiceButton,
              icon: Icon(
                _isListening ? Icons.stop_rounded : Icons.mic_rounded,
                size: 22,
              ),
              label: Text(
                _isListening ? '듣기 종료' : '음성 명령',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                ),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF155EEF),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(13),
                ),
              ),
            ),
          ),
          if (_isNavigating) ...[
            const SizedBox(height: 9),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: OutlinedButton.icon(
                onPressed: _cancelNavigationByVoice,
                icon: const Icon(Icons.close_rounded, size: 20),
                label: const Text(
                  '길안내 종료',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFB42318),
                  side: const BorderSide(color: Color(0xFFE7B8B4)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(13),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSettingsTab() {
    return SingleChildScrollView(
      key: const PageStorageKey<String>('settings-tab'),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '설정',
            style: TextStyle(
              fontSize: 27,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
              color: Color(0xFF16181D),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'SmartCane 연결, 위험 감지 안내, 앱 옵션, 배터리 상태를 확인합니다.',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Color(0xFF747A84),
            ),
          ),
          const SizedBox(height: 20),
          _buildCaneConnectionCard(),
          const SizedBox(height: 14),
          _buildHazardAlertSettingsCard(),
          const SizedBox(height: 14),
          _buildAppOptionsCard(),
          const SizedBox(height: 14),
          _buildCaneStatusCard(),
        ],
      ),
    );
  }

  Widget _buildAppOptionsCard() {
    const Color accent = Color(0xFF155EEF);
    const Color muted = Color(0xFF747A84);

    Widget optionRow({
      required String title,
      required String description,
      required bool value,
      required ValueChanged<bool> onChanged,
    }) {
      // TalkBack이 제목·설명·스위치 상태를 한 번에 읽도록 한 덩어리로 묶는다.
      return MergeSemantics(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF202329),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    description,
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      fontWeight: FontWeight.w600,
                      color: muted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Switch(
              value: value,
              activeThumbColor: Colors.white,
              activeTrackColor: accent,
              onChanged: onChanged,
            ),
          ],
        ),
      );
    }

    return _surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            '앱 옵션',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: Color(0xFF202329),
            ),
          ),
          const SizedBox(height: 12),
          optionRow(
            title: '지팡이 자동 연결',
            description: '앱을 켜면 지팡이를 자동으로 찾아 연결하고, 연결이 끊기면 다시 연결을 시도합니다. 연결 상태는 음성으로 알립니다.',
            value: _autoConnectEnabled,
            onChanged: _setAutoConnectEnabled,
          ),
          const Divider(height: 22, color: Color(0xFFE8EAEE)),
          optionRow(
            title: '큰 글씨',
            description: '앱의 모든 글자를 1.3배로 키웁니다. 저시력 사용자용이며 시스템 글자 크기 설정과 함께 적용됩니다.',
            value: _largeTextEnabled,
            onChanged: _setLargeTextEnabled,
          ),
          const Divider(height: 22, color: Color(0xFFE8EAEE)),
          optionRow(
            title: '간단 모드',
            description: '심사·시연용 카드(인식된 음성, 의도 분석 결과, 카카오 결과, 진동 표시)를 숨기고 음성 버튼과 현재 상태만 표시합니다. 발표 때는 끄세요.',
            value: _simpleModeEnabled,
            onChanged: _setSimpleModeEnabled,
          ),
        ],
      ),
    );
  }

  Widget _buildHazardAlertSettingsCard() {
    const Color accent = Color(0xFF155EEF);
    const Color muted = Color(0xFF747A84);

    return _surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MergeSemantics(
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '위험 감지 안내',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF202329),
                    ),
                  ),
                ),
                Switch(
                  value: _hazardAlertEnabled,
                  activeThumbColor: Colors.white,
                  activeTrackColor: accent,
                  onChanged: _setHazardAlertEnabled,
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _hazardAlertEnabled
                ? '지팡이가 감지한 장애물을 화면과 음성으로 알립니다.'
                : '꺼짐 · 장애물 화면 표시와 음성 안내를 하지 않습니다.',
            style: TextStyle(
              fontSize: 13,
              height: 1.35,
              fontWeight: FontWeight.w600,
              color: _hazardAlertEnabled ? muted : const Color(0xFFB04A4A),
            ),
          ),
          const SizedBox(height: 16),
          for (final String direction in _hazardDirectionDefaultCm.keys) ...<Widget>[
            if (direction != _hazardDirectionDefaultCm.keys.first)
              const Divider(height: 26, color: Color(0xFFE8EAEE)),
            _buildHazardDirectionControl(direction),
          ],
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: TextButton.icon(
              onPressed: _hazardAlertEnabled && _isHazardDistanceLimited
                  ? _resetAllHazardAlertDistances
                  : null,
              icon: const Icon(Icons.restart_alt_rounded, size: 18),
              label: const Text(
                '모두 지팡이 기본 기준으로 되돌리기',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              style: TextButton.styleFrom(foregroundColor: const Color(0xFF555B65)),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '지팡이 기본 기준은 '
            '${_hazardDirectionDefaultCm.entries.map((MapEntry<String, double> entry) => '${_hazardDirectionLabels[entry.key]} ${entry.value.round()}cm').join(', ')}'
            '입니다. 방향마다 바를 밀거나 ± 10cm 버튼, "직접 입력"으로 '
            '${_hazardAlertDistanceMinCm.round()}cm부터 1cm 단위로 줄일 수 있고, '
            '줄인 거리보다 가까운 장애물만 안내하고 진동합니다. '
            '실내처럼 장애물이 늘 가까운 곳에서는 거리를 줄이거나 안내를 꺼서 '
            '물건 찾기 음성이 묻히지 않게 할 수 있습니다.',
            style: const TextStyle(
              fontSize: 12,
              height: 1.45,
              fontWeight: FontWeight.w600,
              color: muted,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _isBleConnected
                ? (_piHazardSettingStatus.isEmpty
                    ? '지팡이 적용 상태 확인 중...'
                    : _piHazardSettingStatus)
                : '지팡이를 연결하면 이 설정이 지팡이의 위험 판정과 진동 경고에도 적용됩니다.',
            style: TextStyle(
              fontSize: 12,
              height: 1.45,
              fontWeight: FontWeight.w700,
              color: _isBleConnected
                  ? (_piHazardSettingStatus.startsWith('지팡이 적용됨')
                      ? const Color(0xFF167A4D)
                      : const Color(0xFF8A6D1F))
                  : muted,
            ),
          ),
        ],
      ),
    );
  }

  /// 한 방향(정면/양쪽/위쪽)의 안내 거리: 바(1cm 단위), − 10cm / 직접 입력 / + 10cm 버튼.
  Widget _buildHazardDirectionControl(String direction) {
    const Color accent = Color(0xFF155EEF);
    const Color muted = Color(0xFF747A84);
    final String label = _hazardDirectionLabels[direction]!;
    final double maxCm = _hazardDirectionDefaultCm[direction]!;
    final double distance = _hazardAlertDistanceCm[direction]!;
    final bool enabled = _hazardAlertEnabled;

    final ButtonStyle buttonStyle = OutlinedButton.styleFrom(
      foregroundColor: accent,
      side: const BorderSide(color: Color(0xFFC9D6F2), width: 1.5),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
      ),
    );
    const TextStyle buttonTextStyle =
        TextStyle(fontSize: 16, fontWeight: FontWeight.w900);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '$label 안내 거리',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF202329),
                ),
              ),
            ),
            Text(
              _isHazardDirectionLimited(direction)
                  ? '${distance.round()}cm 이내'
                  : '기본 ${maxCm.round()}cm',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w900,
                color: enabled ? accent : muted,
              ),
            ),
          ],
        ),
        Semantics(
          label: '$label 위험 안내 거리',
          child: Slider(
            value: distance,
            min: _hazardAlertDistanceMinCm,
            max: maxCm,
            divisions: (maxCm - _hazardAlertDistanceMinCm).round(),
            label: '${distance.round()}cm',
            semanticFormatterCallback: (double value) => '${value.round()}센티미터',
            activeColor: accent,
            onChanged: enabled
                ? (double value) => _setHazardAlertDistance(direction, value)
                : null,
            onChangeEnd: enabled
                ? (double value) => _commitHazardAlertDistance(direction, value)
                : null,
          ),
        ),
        Row(
          children: <Widget>[
            Expanded(
              child: SizedBox(
                height: 48,
                child: OutlinedButton(
                  onPressed: enabled && distance > _hazardAlertDistanceMinCm
                      ? () => _changeHazardAlertDistance(direction, distance - 10)
                      : null,
                  style: buttonStyle,
                  child: Text(
                    '− 10cm',
                    semanticsLabel: '$label 거리 10센티미터 줄이기',
                    style: buttonTextStyle,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SizedBox(
                height: 48,
                child: OutlinedButton(
                  onPressed: enabled
                      ? () => _promptHazardAlertDistance(direction)
                      : null,
                  style: buttonStyle,
                  child: Text(
                    '직접 입력',
                    semanticsLabel: '$label 거리 직접 입력',
                    style: buttonTextStyle,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SizedBox(
                height: 48,
                child: OutlinedButton(
                  onPressed: enabled && distance < maxCm
                      ? () => _changeHazardAlertDistance(direction, distance + 10)
                      : null,
                  style: buttonStyle,
                  child: Text(
                    '+ 10cm',
                    semanticsLabel: '$label 거리 10센티미터 늘리기',
                    style: buttonTextStyle,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCaneConnectionCard() {
    return _surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '지팡이 연결',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: Color(0xFF202329),
            ),
          ),
          const SizedBox(height: 15),
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: _isBleConnected
                      ? const Color(0xFFECF8F2)
                      : const Color(0xFFF1F3F5),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  _isBleConnected
                      ? Icons.bluetooth_connected_rounded
                      : Icons.bluetooth_rounded,
                  color: _isBleConnected
                      ? const Color(0xFF1D9B62)
                      : const Color(0xFF6F747D),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'SmartCane',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF202329),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _bleStatus,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.35,
                        fontWeight: FontWeight.w600,
                        color: _isBleConnected
                            ? const Color(0xFF167A4D)
                            : const Color(0xFF747A84),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_bleDevice == null)
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton.icon(
                onPressed: _isBleScanning ? null : _scanSmartCane,
                icon: _isBleScanning
                    ? const SizedBox(
                        width: 17,
                        height: 17,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.search_rounded),
                label: Text(
                  _isBleScanning ? '검색 중' : 'SmartCane 찾기',
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF155EEF),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(13),
                  ),
                ),
              ),
            )
          else
            Row(
              children: [
                if (!_isBleConnected) ...[
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: OutlinedButton.icon(
                        onPressed: _isBleScanning ? null : _scanSmartCane,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text(
                          '다시 검색',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF555B65),
                          side: const BorderSide(color: Color(0xFFD3D7DE)),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(13),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 9),
                ],
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: FilledButton(
                      onPressed: _isBleConnected
                          ? _disconnectSmartCane
                          : _connectSmartCane,
                      style: FilledButton.styleFrom(
                        backgroundColor: _isBleConnected
                            ? const Color(0xFF4F5661)
                            : const Color(0xFF155EEF),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(13),
                        ),
                      ),
                      child: Text(
                        _isBleConnected ? '연결 해제' : '연결',
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildCaneStatusCard() {
    final String battery = _piBattery == null
        ? '-'
        : '${_piBattery!.toStringAsFixed(0)}%';

    return _surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '기기 상태',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF202329),
                  ),
                ),
              ),
              Text(
                _statusUpdatedLabel(),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF7A8089),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildSimpleStatusRow(
            icon: Icons.battery_5_bar_rounded,
            label: '배터리',
            value: battery,
          ),
          const Divider(height: 24, color: Color(0xFFE8EAEE)),
          _buildSimpleStatusRow(
            icon: Icons.battery_charging_full_rounded,
            label: '충전 상태',
            value: _chargingLabel(),
          ),
        ],
      ),
    );
  }

  Widget _buildSimpleStatusRow({
    required IconData icon,
    required String label,
    required String value,
    Color? valueColor,
  }) {
    return Row(
      children: [
        Icon(icon, size: 22, color: const Color(0xFF656B75)),
        const SizedBox(width: 11),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: Color(0xFF555B65),
            ),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w900,
            color: valueColor ?? const Color(0xFF202329),
          ),
        ),
      ],
    );
  }

  Widget _buildBottomNavigation() {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(
          top: BorderSide(color: Color(0xFFE2E5EA), width: 1),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(18, 7, 18, 8),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: _BottomItem(
                icon: Icons.home_outlined,
                selectedIcon: Icons.home_rounded,
                label: '홈',
                selected: _selectedTabIndex == 0,
                onTap: () => setState(() => _selectedTabIndex = 0),
              ),
            ),
            Expanded(
              child: _BottomItem(
                icon: Icons.signpost_outlined,
                selectedIcon: Icons.signpost_rounded,
                label: '길안내',
                selected: _selectedTabIndex == 1,
                onTap: () => setState(() => _selectedTabIndex = 1),
              ),
            ),
            Expanded(
              child: _BottomItem(
                icon: Icons.settings_outlined,
                selectedIcon: Icons.settings_rounded,
                label: '설정',
                selected: _selectedTabIndex == 2,
                onTap: () => setState(() => _selectedTabIndex = 2),
              ),
            ),
          ],
        ),
      ),
    );
  }

}
class _BottomItem extends StatelessWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _BottomItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final Color color = selected
        ? const Color(0xFF155EEF)
        : const Color(0xFF7A808A);

    return Semantics(
      button: true,
      selected: selected,
      label: '$label 탭',
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        // 큰 글씨 + 시스템 글자 크기 최대에서도 잘리지 않도록 고정 높이를 쓰지 않는다.
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                selected ? selectedIcon : icon,
                size: 25,
                color: color,
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w900 : FontWeight.w700,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class IntentAnalysisResult {
  final String intent;
  final String coreContent;
  final String appAction;
  final String target;
  final String targetLabel;
  final String destination;
  final String placeName;

  const IntentAnalysisResult({
    required this.intent,
    required this.coreContent,
    required this.appAction,
    required this.target,
    required this.targetLabel,
    required this.destination,
    this.placeName = '',
  });

  /// GPT 스키마에 정의된 intent 값인지. 아니면 API 오류/빈 응답 같은 실패다.
  static const Set<String> knownIntents = <String>{
    'find_object',
    'navigate',
    'stop',
    'status',
    'where_am_i',
    'repeat',
    'save_place',
    'delete_place',
    'connect',
    'disconnect',
    'unknown',
  };

  static bool isKnownIntent(String intent) =>
      knownIntents.contains(intent.trim());

  factory IntentAnalysisResult.empty() {
    return const IntentAnalysisResult(
      intent: '-',
      coreContent: '-',
      appAction: '-',
      target: '',
      targetLabel: '',
      destination: '',
    );
  }

  factory IntentAnalysisResult.error({
    required String intent,
    required String coreContent,
    required String appAction,
  }) {
    return IntentAnalysisResult(
      intent: intent,
      coreContent: coreContent,
      appAction: appAction,
      target: '',
      targetLabel: '',
      destination: '',
    );
  }

  factory IntentAnalysisResult.fromJson(Map<String, dynamic> json) {
    return IntentAnalysisResult(
      intent: json['intent']?.toString().trim() ?? 'unknown',
      coreContent: json['coreContent']?.toString().trim() ?? '-',
      appAction: json['appAction']?.toString().trim() ?? '-',
      target: json['target']?.toString().trim() ?? '',
      targetLabel: json['targetLabel']?.toString().trim() ?? '',
      destination: json['destination']?.toString().trim() ?? '',
      placeName: json['placeName']?.toString().trim() ?? '',
    );
  }
}

/// 활동 로그 한 건 (심사용 로그 카드)
/// - toPi == true : 앱 → 지팡이 BLE 명령
/// - toPi == false: 지팡이 → 앱 BLE 패킷
/// - toPi == null : 앱 내부 사건 (장소 저장, 경로 탐색 완료, 상태 안내, 연결 상태)
class BleLogEntry {
  final DateTime at;
  final bool? toPi;
  final String raw;
  final String easy;
  final String category; // hazard / object / navigation / status / place / connection / other

  const BleLogEntry({
    required this.at,
    required this.toPi,
    required this.raw,
    required this.easy,
    required this.category,
  });
}

/// 로그 카드 필터 항목 (key, 표시 이름)
const List<MapEntry<String, String>> kBleLogCategories = <MapEntry<String, String>>[
  MapEntry<String, String>('', '전체'),
  MapEntry<String, String>('hazard', '장애물 감지'),
  MapEntry<String, String>('object', '물건 찾기'),
  MapEntry<String, String>('navigation', '길안내'),
  MapEntry<String, String>('status', '상태 확인'),
  MapEntry<String, String>('place', '장소 저장'),
  MapEntry<String, String>('connection', '연결'),
];

/// 장소 이름(+검색어) 입력 다이얼로그. 컨트롤러 수명을 다이얼로그와 같이 가져간다.
class _PlaceInputDialog extends StatefulWidget {
  final String title;
  final bool askKeyword;

  const _PlaceInputDialog({required this.title, required this.askKeyword});

  @override
  State<_PlaceInputDialog> createState() => _PlaceInputDialogState();
}

class _PlaceInputDialogState extends State<_PlaceInputDialog> {
  static const List<String> _quickNames = <String>['집', '회사', '학교'];
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _keywordController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _keywordController.dispose();
    super.dispose();
  }

  bool get _canSave =>
      _nameController.text.trim().isNotEmpty &&
      (!widget.askKeyword || _keywordController.text.trim().isNotEmpty);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: 8,
            children: _quickNames
                .map(
                  (String quick) => ChoiceChip(
                    label: Text(quick),
                    selected: _nameController.text == quick,
                    onSelected: (_) => setState(() {
                      _nameController.text = quick;
                    }),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _nameController,
            autofocus: true,
            textInputAction: widget.askKeyword
                ? TextInputAction.next
                : TextInputAction.done,
            decoration: const InputDecoration(
              labelText: '저장 이름',
              hintText: '예: 집, 회사, 할머니댁',
            ),
            onChanged: (_) => setState(() {}),
          ),
          if (widget.askKeyword) ...<Widget>[
            const SizedBox(height: 10),
            TextField(
              controller: _keywordController,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: '검색할 장소',
                hintText: '예: 스타벅스 강남점, 서원대학교',
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          // 이름(검색 저장이면 검색어도)이 비어 있으면 눌리지 않는다.
          onPressed: !_canSave
              ? null
              : () => Navigator.of(context).pop(<String, String>{
                    'name': _nameController.text.trim(),
                    'keyword': _keywordController.text.trim(),
                  }),
          child: const Text('저장'),
        ),
      ],
    );
  }
}

/// 위험 안내 거리(cm) 직접 입력 다이얼로그. 범위를 벗어나면 적용 버튼이 눌리지 않는다.
/// 컨트롤러 수명을 다이얼로그와 같이 가져간다(`_PlaceInputDialog`와 같은 이유).
class _HazardDistanceInputDialog extends StatefulWidget {
  final String label;
  final int initialCm;
  final int minCm;
  final int maxCm;

  const _HazardDistanceInputDialog({
    required this.label,
    required this.initialCm,
    required this.minCm,
    required this.maxCm,
  });

  @override
  State<_HazardDistanceInputDialog> createState() =>
      _HazardDistanceInputDialogState();
}

class _HazardDistanceInputDialogState extends State<_HazardDistanceInputDialog> {
  // 처음 값을 전체 선택해 두어 바로 새 숫자를 치면 덮어써진다.
  late final TextEditingController _controller = TextEditingController(
    text: '${widget.initialCm}',
  )..selection = TextSelection(
      baseOffset: 0,
      extentOffset: '${widget.initialCm}'.length,
    );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int? get _value {
    final int? parsed = int.tryParse(_controller.text.trim());
    if (parsed == null || parsed < widget.minCm || parsed > widget.maxCm) {
      return null;
    }
    return parsed;
  }

  void _submit() {
    final int? value = _value;
    if (value != null) Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final String range = '${widget.minCm}~${widget.maxCm}cm';
    final bool invalid = _controller.text.trim().isNotEmpty && _value == null;

    return AlertDialog(
      title: Text('${widget.label} 위험 안내 거리'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: <TextInputFormatter>[
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(3),
        ],
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          labelText: '거리',
          suffixText: 'cm',
          helperText: '$range 사이 숫자 (${widget.maxCm}cm = 지팡이 기본 기준)',
          helperMaxLines: 2,
          errorText: invalid ? '$range 사이로 입력하세요' : null,
        ),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _submit(),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _value == null ? null : _submit,
          child: const Text('적용'),
        ),
      ],
    );
  }
}

/// 사용자가 이름을 붙여 저장한 장소 (집, 회사 등)
class SavedPlace {
  final String name;
  final String address;
  final double longitude;
  final double latitude;
  final DateTime savedAt;

  const SavedPlace({
    required this.name,
    required this.address,
    required this.longitude,
    required this.latitude,
    required this.savedAt,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'address': address,
        'longitude': longitude,
        'latitude': latitude,
        'savedAt': savedAt.toIso8601String(),
      };

  factory SavedPlace.fromJson(Map<String, dynamic> json) {
    return SavedPlace(
      name: json['name']?.toString().trim() ?? '',
      address: json['address']?.toString() ?? '',
      longitude: (json['longitude'] as num?)?.toDouble() ?? 0.0,
      latitude: (json['latitude'] as num?)?.toDouble() ?? 0.0,
      savedAt: DateTime.tryParse(json['savedAt']?.toString() ?? '') ??
          DateTime.now(),
    );
  }

  KakaoPlace toKakaoPlace() => KakaoPlace(
        name: name,
        address: address,
        longitude: longitude,
        latitude: latitude,
      );

  IconData get icon {
    final String key = name.replaceAll(' ', '');
    if (key.contains('집') || key.contains('홈')) return Icons.home_rounded;
    if (key.contains('회사') || key.contains('직장') || key.contains('사무실')) {
      return Icons.work_rounded;
    }
    if (key.contains('학교') || key.contains('대학')) return Icons.school_rounded;
    if (key.contains('병원')) return Icons.local_hospital_rounded;
    return Icons.star_rounded;
  }
}

/// 길찾기·장소 검색 실패를 사용자에게 읽어 줄 문장([spoken])과
/// 로그용 상세([detail])로 나눈 예외.
class NavigationFailure implements Exception {
  final String spoken;
  final String detail;

  const NavigationFailure(this.spoken, {String? detail})
      : detail = detail ?? spoken;

  @override
  String toString() => detail;
}

class KakaoPlace {
  final String name;
  final String address;
  final double longitude;
  final double latitude;

  const KakaoPlace({
    required this.name,
    required this.address,
    required this.longitude,
    required this.latitude,
  });

  factory KakaoPlace.fromJson(Map<String, dynamic> json) {
    final String roadAddress = json['road_address_name']?.toString() ?? '';
    final String normalAddress = json['address_name']?.toString() ?? '';

    return KakaoPlace(
      name: json['place_name']?.toString() ?? '',
      address: roadAddress.isNotEmpty ? roadAddress : normalAddress,
      longitude: double.tryParse(json['x']?.toString() ?? '') ?? 0.0,
      latitude: double.tryParse(json['y']?.toString() ?? '') ?? 0.0,
    );
  }
}

class KakaoWalkRoute {
  final int totalDistance;
  final int totalTime;
  final String firstGuide;
  final List<List<double>> points;
  final List<KakaoNavigationStep> navigationSteps;

  const KakaoWalkRoute({
    required this.totalDistance,
    required this.totalTime,
    required this.firstGuide,
    required this.points,
    required this.navigationSteps,
  });

  factory KakaoWalkRoute.fromJson(Map<String, dynamic> json) {
    final dynamic routeData = json['route'];

    Map<String, dynamic> route = {};

    if (routeData is Map) {
      route = Map<String, dynamic>.from(routeData);
    } else if (routeData is List && routeData.isNotEmpty) {
      route = Map<String, dynamic>.from(routeData.first as Map);
    }

    final Map<String, dynamic> properties = route['properties'] is Map
        ? Map<String, dynamic>.from(route['properties'] as Map)
        : {};

    String firstGuide = '안내 문구가 없습니다.';
    final List<List<double>> routePoints = [];
    final List<KakaoNavigationStep> navigationSteps = [];
    final dynamic legsData = route['legs'];

    if (legsData is List) {
      for (final dynamic legData in legsData) {
        if (legData is! Map) continue;

        final Map<String, dynamic> leg =
            Map<String, dynamic>.from(legData);
        final dynamic stepsData = leg['steps'];

        if (stepsData is! List) continue;

        for (final dynamic stepData in stepsData) {
          if (stepData is! Map) continue;

          final Map<String, dynamic> step =
              Map<String, dynamic>.from(stepData);
          final Map<String, dynamic> stepProperties =
              step['properties'] is Map
                  ? Map<String, dynamic>.from(step['properties'] as Map)
                  : {};
          final String guidance =
              stepProperties['guidance']?.toString() ?? '';

          if (firstGuide == '안내 문구가 없습니다.' && guidance.isNotEmpty) {
            firstGuide = guidance;
          }

          final Map<String, dynamic> path = step['path'] is Map
              ? Map<String, dynamic>.from(step['path'] as Map)
              : {};
          final dynamic pointsData = path['points'];
          final List<List<double>> stepPoints = [];

          if (pointsData is List) {
            for (final dynamic pointData in pointsData) {
              if (pointData is! List || pointData.length < 2) continue;

              final double? longitude = _toDouble(pointData[0]);
              final double? latitude = _toDouble(pointData[1]);

              if (longitude == null || latitude == null) continue;

              final List<double> newPoint = [longitude, latitude];
              stepPoints.add(newPoint);

              if (routePoints.isEmpty ||
                  routePoints.last[0] != newPoint[0] ||
                  routePoints.last[1] != newPoint[1]) {
                routePoints.add(newPoint);
              }
            }
          }

          double? guideLongitude;
          double? guideLatitude;
          double? stepBearing;

          if (stepPoints.isNotEmpty) {
            // 현재 안내 구간의 끝점에 도착하면 다음 안내로 넘어간다.
            guideLongitude = stepPoints.last[0];
            guideLatitude = stepPoints.last[1];

            if (stepPoints.length >= 2) {
              stepBearing = _calculateBearing(
                startLongitude: stepPoints.first[0],
                startLatitude: stepPoints.first[1],
                endLongitude: stepPoints.last[0],
                endLatitude: stepPoints.last[1],
              );
            }
          } else {
            guideLongitude = _toDouble(stepProperties['x']);
            guideLatitude = _toDouble(stepProperties['y']);
          }

          if (guidance.isNotEmpty &&
              guideLongitude != null &&
              guideLatitude != null &&
              guideLongitude >= 124 &&
              guideLongitude <= 132 &&
              guideLatitude >= 32 &&
              guideLatitude <= 40) {
            navigationSteps.add(
              KakaoNavigationStep(
                guidance: guidance,
                distance: _toInt(stepProperties['distance']),
                longitude: guideLongitude,
                latitude: guideLatitude,
                bearing: stepBearing,
                pathPoints: List<List<double>>.unmodifiable(stepPoints),
              ),
            );
          }
        }
      }
    }

    return KakaoWalkRoute(
      totalDistance: _toInt(properties['totalDistance']),
      totalTime: _toInt(properties['totalTime']),
      firstGuide: firstGuide,
      points: routePoints,
      navigationSteps: navigationSteps,
    );
  }

  static int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static double? _toDouble(dynamic value) {
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }

  static double _calculateBearing({
    required double startLongitude,
    required double startLatitude,
    required double endLongitude,
    required double endLatitude,
  }) {
    final double startLat = startLatitude * math.pi / 180;
    final double endLat = endLatitude * math.pi / 180;
    final double longitudeDifference =
        (endLongitude - startLongitude) * math.pi / 180;
    final double y = math.sin(longitudeDifference) * math.cos(endLat);
    final double x = math.cos(startLat) * math.sin(endLat) -
        math.sin(startLat) *
            math.cos(endLat) *
            math.cos(longitudeDifference);

    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }
}

class KakaoNavigationStep {
  final String guidance;
  final int distance;
  final double longitude;
  final double latitude;
  final double? bearing;
  final List<List<double>> pathPoints;

  const KakaoNavigationStep({
    required this.guidance,
    required this.distance,
    required this.longitude,
    required this.latitude,
    required this.bearing,
    required this.pathPoints,
  });
}
