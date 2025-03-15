import 'dart:async';
import 'dart:convert';
import 'dart:collection';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'package:location/location.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart'; // For LatLng coordinates
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';

// Constants for optimization
const int TARGET_WIDTH = 640;
const int JPEG_QUALITY = 65;
const int FRAME_INTERVAL_MS = 100; // 30 fps
const int LOCATION_INTERVAL_MS = 3000;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Keep screen on during streaming
  await WakelockPlus.enable();

  // Set preferred orientation to portrait
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  final cameras = await availableCameras();
  runApp(MyApp(cameras: cameras));
}

class MyApp extends StatelessWidget {
  final List<CameraDescription> cameras;

  const MyApp({Key? key, required this.cameras}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Navigation Assistant',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        brightness: Brightness.dark, // Dark theme for better visibility outdoors
      ),
      home: HomePage(cameras: cameras),
    );
  }
}

class HomePage extends StatefulWidget {
  final List<CameraDescription> cameras;

  const HomePage({Key? key, required this.cameras}) : super(key: key);

  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  bool isServer = false;
  bool isConnected = false;
  String ipAddress = "";
  int port = 8080;

  // WebSocket server/client
  HttpServer? server;
  WebSocketChannel? channel;
  List<WebSocket> clients = [];

  // Camera
  CameraController? cameraController;
  bool isCameraInitialized = false;
  bool isStreaming = false;

  // Bluetooth
  FlutterBluetoothSerial _bluetooth = FlutterBluetoothSerial.instance;
  BluetoothConnection? btConnection;
  bool isBtConnecting = false;
  bool isBtConnected = false;
  bool isBtDisconnecting = false;

  // Text-to-Speech
  FlutterTts flutterTts = FlutterTts();
  Queue<String> ttsQueue = Queue<String>();
  bool isSpeaking = false;
  Timer? ttsQueueTimer;


  // Define priority messages that should interrupt current speech
  Set<String> priorityMessages = {'TB', 'OAS', 'CD'};

  // Arduino data
  String receivedData = "";
  String lastAlert = "";

  // Device details
  String deviceAddress = "98:D3:71:F7:06:9B"; // HC-05 MAC address

  // Optimization: Use a flag to control frame processing
  bool isProcessingFrame = false;

  // Frame counter for statistics
  int framesSent = 0;
  int framesReceived = 0;
  int totalBytesSent = 0;
  DateTime? statisticsStartTime;

  // Throttled frame processing
  DateTime? lastFrameTime;

  // Location
  Location location = Location();
  LocationData? currentLocation;
  Timer? locationTimer;
  Timer? statisticsTimer;

  // For receiver
  Uint8List? receivedImageData;
  LocationData? remoteLocation;

  // Connection quality indicator
  double connectionQuality = 0.0; // 0.0 to 1.0
  int latencyMs = 0;
  Timer? pingTimer;
  DateTime? lastPingSent;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    checkPermissions();
    _initPermissions();
    _initTextToSpeech();

    // Initialize statistics timer
    statisticsTimer = Timer.periodic(Duration(seconds: 5), (_) {
      _updateStatistics();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cleanupResources();
    ttsQueueTimer?.cancel();
    flutterTts.stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (cameraController == null || !cameraController!.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive) {
      _cleanupResources();
    } else if (state == AppLifecycleState.resumed) {
      if (isServer) {
        initCamera();
      }
    }
  }

  Future<void> _initPermissions() async {
    // Request necessary permissions
    await Permission.bluetooth.request();
    await Permission.bluetoothConnect.request();
    await Permission.bluetoothScan.request();
    await Permission.microphone.request();
    await Permission.camera.request();
  }

  Future<void> _initTextToSpeech() async {
    await flutterTts.setLanguage("en-US");
    await flutterTts.setSpeechRate(0.8);
    await flutterTts.setVolume(1.0);
    await flutterTts.setPitch(1.0);

    // completion listener
    flutterTts.setCompletionHandler(() {
      isSpeaking = false;
      _processNextTtsMessage();
    });

    // error listener
    flutterTts.setErrorHandler((msg) {
      print("TTS Error: $msg");
      isSpeaking = false;
      _processNextTtsMessage(); // Try the next message
    });

    // queue processor
    ttsQueueTimer = Timer.periodic(Duration(milliseconds: 100), (timer) {
      if (!isSpeaking && ttsQueue.isNotEmpty) {
        _processNextTtsMessage();
      }
    });
  }

  void _processNextTtsMessage() {
    if (ttsQueue.isEmpty || isSpeaking) return;

    String message = ttsQueue.removeFirst();
    _speakMessageDirectly(message);
  }

  Future<void> _speakMessageDirectly(String message) async {
    try {
      isSpeaking = true;
      await flutterTts.speak(message);
    } catch (e) {
      print("TTS Direct Speak Error: ${e.toString()}");
      isSpeaking = false;
      _processNextTtsMessage();
      _processNextTtsMessage();
    }
  }

  Widget _buildSensorIndicator(String label, int value) {
    Color color = Colors.green;
    if (value <= 10) {
      color = Colors.red;
    } else if (value <= 20) {
      color = Colors.orange;
    }

    return Column(
      children: [
        Container(
          width: 60,
          height: 60,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withOpacity(0.2),
            border: Border.all(color: color, width: 2),
          ),
          child: Center(
            child: Text(
              "$value cm",
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ),
        ),
        SizedBox(height: 4),
        Text(label, style: TextStyle(fontSize: 12)),
      ],
    );
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text("Error"),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: Text("OK"),
            ),
          ],
        );
      },
    );
  }

  void scanForArduino() async {
    List<BluetoothDevice> devices = [];

    try {
      devices = await _bluetooth.getBondedDevices();
    } catch (e) {
      _showErrorDialog("Failed to get Bluetooth devices: ${e.toString()}");
      return;
    }

    if (devices.isEmpty) {
      _showErrorDialog("No paired Bluetooth devices found. Please pair your HC-05 in device settings first.");
      return;
    }


    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text("Select HC-05 Device"),
          content: Container(
            width: double.maxFinite,
            height: 300,
            child: ListView.builder(
              itemCount: devices.length,
              itemBuilder: (context, index) {
                return ListTile(
                  title: Text(devices[index].name ?? "Unknown Device"),
                  subtitle: Text(devices[index].address),
                  onTap: () {
                    setState(() {
                      deviceAddress = devices[index].address;
                    });
                    Navigator.of(context).pop();
                    connectToArduino();
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: Text("Cancel"),
            ),
          ],
        );
      },
    );
  }

  void connectToArduino() async {
    if (deviceAddress.isEmpty) {
      scanForArduino();
      return;
    }

    setState(() {
      isBtConnecting = true;
    });

    try {
      btConnection = await BluetoothConnection.toAddress(deviceAddress);

      setState(() {
        isBtConnecting = false;
        isBtConnected = true;
      });

      // Buffer for handling fragmented messages
      StringBuffer dataBuffer = StringBuffer();

      // Listen for incoming data from Arduino
      btConnection!.input!.listen((Uint8List data) {
        String incomingData = ascii.decode(data).trim();
        // Add to buffer
        dataBuffer.write(incomingData);
        // Process complete messages (assuming messages end with newline or similar delimiter)
        if (incomingData.contains('\n') || incomingData.contains('\r')) {
          String completeData = dataBuffer.toString().trim();
          // Clear buffer after processing
          dataBuffer.clear();

          // Process each message if multiple are received
          for (String message in completeData.split(RegExp(r'[\r\n]+'))) {
            if (message.isNotEmpty) {
              _processReceivedData(message);
            }
          }
        }
      }).onDone(() {
        setState(() {
          isBtConnected = false;
        });
      });

    } catch (e) {
      setState(() {
        isBtConnecting = false;
      });
      _showErrorDialog("Failed to connect to Arduino: ${e.toString()}");
    }
  }

  void disconnectFromArduino() async {
    setState(() {
      isBtDisconnecting = true;
    });

    await btConnection?.close();

    setState(() {
      isBtDisconnecting = false;
      isBtConnected = false;
    });
  }

  Future<void> _speakMessage(String message) async {
    // Check if this is a priority message
    if (priorityMessages.contains(receivedData)) {
      // For priority messages, stop current speech and speak immediately
      await flutterTts.stop();
      ttsQueue.clear(); // Clear queue for urgent messages
      ttsQueue.addFirst(message); // Add to front of queue
    } else {
      // For regular messages, add to queue
      ttsQueue.add(message);
    }

    // If not speaking, process immediately
    if (!isSpeaking) {
      _processNextTtsMessage();
    }
  }
  void _processReceivedData(String data) {
    // Trim the data to remove any whitespace
    final String cleanData = data.trim();

    // Log the received data for debugging
    print("Received data: '$cleanData'");
    setState(() {
      receivedData = cleanData;
    });

    // Map of codes to their corresponding messages
    final Map<String, String> messageMap = {
      "TB": "Turn Back",
      "OAS": "Obstacle Ahead Stop",
      "SRTN": "Sharp Right Turn Needed",
      "TR": "Turn Right",
      "OB": "Obstacle on Both Sides",
      "SLTN": "Sharp Left Turn Needed",
      "TL": "Turn Left",
      "PC": "Path Clear Proceed",
      "NP": "Caution! Narrow Passage",
      "CD": "Caution! Obstacle nearby",
    };

    if (messageMap.containsKey(cleanData)) {
      _speakMessage(messageMap[cleanData]!);

      // Update lastAlert for UI display
      setState(() {
        lastAlert = messageMap[cleanData]!;
      });
    } else {
      // If we receive an unknown code, log it for debugging
      print("Unknown message code received: '$cleanData'");
    }
  }
  void _cleanupResources() {
    stopStreaming();
    cameraController?.dispose();
    locationTimer?.cancel();
    statisticsTimer?.cancel();
    pingTimer?.cancel();
    channel?.sink.close();
    server?.close();
    WakelockPlus.disable();
  }

  void checkPermissions() async {
    // Check location permission
    bool serviceEnabled = await location.serviceEnabled();
    if (!serviceEnabled) {
      serviceEnabled = await location.requestService();
      if (!serviceEnabled) return;
    }

    // Configure location service for better accuracy
    await location.changeSettings(
      accuracy: LocationAccuracy.high,
      interval: LOCATION_INTERVAL_MS,
      distanceFilter: 5, // meters
    );

    // Start receiving location updates
    location.onLocationChanged.listen((LocationData locationData) {
      setState(() {
        currentLocation = locationData;
      });
    });
  }

  void initCamera() async {
    if (widget.cameras.isEmpty) {
      print("No cameras available.");
      return;
    }

    print("Initializing camera...");

    // Select the best camera for navigation assistance
    final CameraDescription selectedCamera = _selectOptimalCamera(widget.cameras);

    cameraController = CameraController(
      selectedCamera,
      ResolutionPreset.high, // Lower resolution for better streaming performance
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420, // Optimized format for processing
    );

    try {
      await cameraController!.initialize();

      // Set exposure mode for outdoor usage
      if (cameraController!.value.isInitialized) {
        await cameraController!.setExposureMode(ExposureMode.auto);
        await cameraController!.setFocusMode(FocusMode.auto);
      }

      // Important: set this to true only after successful initialization
      if (mounted) {
        setState(() {
          isCameraInitialized = true;
        });
      }

      // Start streaming if this is the server
      if (isServer) {
        startStreaming();
      }
    } catch (e) {
      print('Error initializing camera: $e');
    }
  }

  CameraDescription _selectOptimalCamera(List<CameraDescription> cameras) {
    // Prefer back camera for navigation assistance
    try {
      return cameras.firstWhere(
            (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
    } catch (e) {
      return cameras.first;
    }
  }

  void startServer() async {
    int retryCount = 0;
    const int maxRetries = 5;
    const int basePort = 8080;

    try {
      setState(() {
        isServer = true;
      });

      // Get hotspot IP address
      final info = NetworkInfo();
      final wifiIP = await info.getWifiIP();
      ipAddress = wifiIP ?? "192.168.43.1"; // Default hotspot IP

      // Start WebSocket server
      while (retryCount < maxRetries){
        try {
          server = await HttpServer.bind(InternetAddress.anyIPv4, basePort + retryCount);
          port = basePort + retryCount; // Update the port variable
          print('Server started at $ipAddress:$port');
          break; // Exit the loop if binding succeeds
        } on SocketException catch (e) {
          retryCount++;
          if (retryCount >= maxRetries) {
            print('Failed to start server after $maxRetries attempts: $e');
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Failed to start server: $e')),
            );
            return;
          }
          print('Port ${basePort + retryCount - 1} in use, retrying with port ${basePort + retryCount}');
        }
      }

      // Reset statistics
      framesSent = 0;
      totalBytesSent = 0;
      statisticsStartTime = DateTime.now();

      // Show connection info
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: Text('Server Started'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Hotspot IP Address: $ipAddress'),
              Text('Port: $port'),
              Text('Connect the other device using these details'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('OK'),
            ),
          ],
        ),
      );

      // Initialize camera
      initCamera();

      // Listen for WebSocket connections
      server!.transform(WebSocketTransformer()).listen((WebSocket ws) {
        print('Client connected');

        // Enable compression if supported
        try {
          (ws as dynamic).compression = true;
        } catch (e) {
          print('WebSocket compression not supported: $e');
        }

        setState(() {
          clients.add(ws);
          isConnected = true;
        });

        // Handle client connection established - restart streaming if needed
        if (isServer && isCameraInitialized && clients.isNotEmpty && !isStreaming) {
          startStreaming();
        }

        // Start ping-pong for latency measurement
        _startPingPong(ws);

        // Listen for messages from client
        ws.listen((message) {
          _handleIncomingMessage(message, ws);
        }, onDone: () {
          print('Client disconnected');
          clients.remove(ws);
          if (clients.isEmpty) {
            setState(() {
              isConnected = false;
            });

            // Stop streaming if no clients
            if (isStreaming) {
              stopStreaming();
            }
          }
        }, onError: (error) {
          print('WebSocket error: $error');
          clients.remove(ws);
          if (clients.isEmpty) {
            setState(() {
              isConnected = false;
            });

            // Stop streaming if no clients
            if (isStreaming) {
              stopStreaming();
            }
          }
        });
      });

      // Start sending location updates - optimized interval
      locationTimer = Timer.periodic(Duration(milliseconds: LOCATION_INTERVAL_MS), (timer) {
        _sendLocationToClients();
      });
    } catch (e) {
      print('Error starting server: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error starting server: $e')),
      );
    }
  }

  void _startPingPong(WebSocket ws) {
    // Send ping every 2 seconds to measure connection quality
    pingTimer = Timer.periodic(Duration(seconds: 2), (timer) {
      if (clients.contains(ws)) {
        try {
          lastPingSent = DateTime.now();
          ws.add('PING:${lastPingSent!.millisecondsSinceEpoch}');
        } catch (e) {
          print('Error sending ping: $e');
        }
      }
    });
  }

  void _handleIncomingMessage(dynamic message, WebSocket ws) {
    if (message is String && message.startsWith('PONG:')) {
      // Handle latency measurement
      try {
        final pingTime = int.parse(message.substring(5));
        final now = DateTime.now().millisecondsSinceEpoch;
        latencyMs = now - pingTime;

        // Update connection quality based on latency
        // Lower latency = better quality (up to a point)
        if (latencyMs < 50) {
          connectionQuality = 1.0; // Excellent
        } else if (latencyMs < 100) {
          connectionQuality = 0.9; // Very good
        } else if (latencyMs < 200) {
          connectionQuality = 0.7; // Good
        } else if (latencyMs < 500) {
          connectionQuality = 0.5; // Fair
        } else {
          connectionQuality = 0.3; // Poor
        }

        setState(() {});
      } catch (e) {
        print('Error processing pong: $e');
      }
    } else if (message is String && message.startsWith('PING:')) {
      // Respond to ping
      try {
        ws.add('PONG:${message.substring(5)}');
      } catch (e) {
        print('Error sending pong: $e');
      }
    } else if (message is Uint8List && message.length == 24) {
      // Binary location data format (3 doubles: lat, lng, accuracy)
      ByteData byteData = ByteData.view(message.buffer);
      setState(() {
        remoteLocation = LocationData.fromMap({
          'latitude': byteData.getFloat64(0),
          'longitude': byteData.getFloat64(8),
          'accuracy': byteData.getFloat64(16),
        });
      });
    } else if (message is String && message.startsWith('LOCATION:')) {
      final locationParts = message.substring(9).split(',');
      if (locationParts.length >= 2) {
        setState(() {
          remoteLocation = LocationData.fromMap({
            'latitude': double.parse(locationParts[0]),
            'longitude': double.parse(locationParts[1]),
            'accuracy': locationParts.length > 2 ? double.parse(locationParts[2]) : 0.0,
          });
        });
      }
    }
  }

  void _sendLocationToClients() {
    if (currentLocation != null && clients.isNotEmpty) {
      for (var client in List.from(clients)) {
        try {
          // Send location in binary format for efficiency
          ByteData data = ByteData(24); // 3 doubles at 8 bytes each
          data.setFloat64(0, currentLocation!.latitude ?? 0);
          data.setFloat64(8, currentLocation!.longitude ?? 0);
          data.setFloat64(16, currentLocation!.accuracy ?? 0);
          client.add(Uint8List.view(data.buffer));
        } catch (e) {
          print('Error sending location: $e');
          clients.remove(client);
        }
      }
    }
  }

  void startStreaming() {
    if (cameraController == null || !cameraController!.value.isInitialized) {
      print('Camera not initialized');
      return;
    }

    // Already streaming
    if (isStreaming) {
      return;
    }

    setState(() {
      isStreaming = true;
      framesSent = 0;
      totalBytesSent = 0;
      statisticsStartTime = DateTime.now();
    });

    // Use image stream with throttling for better performance
    try {
      cameraController!.startImageStream((CameraImage image) {
        // Process frames at a controlled rate to avoid overwhelming the system
        final now = DateTime.now();
        if (lastFrameTime == null ||
            now.difference(lastFrameTime!).inMilliseconds >= FRAME_INTERVAL_MS) {
          lastFrameTime = now;

          // Only process if not currently processing a frame and have clients
          if (!isProcessingFrame && isServer && clients.isNotEmpty) {
            isProcessingFrame = true;
            _processAndSendCameraImage(image).then((_) {
              isProcessingFrame = false;
            });
          }
        }
      });
    } catch (e) {
      print('Error starting image stream: $e');
      setState(() {
        isStreaming = false;
      });
    }
  }

  void stopStreaming() {
    if (cameraController != null && cameraController!.value.isStreamingImages) {
      try {
        cameraController!.stopImageStream();
      } catch (e) {
        print('Error stopping image stream: $e');
      }
    }

    setState(() {
      isStreaming = false;
    });
  }


Future<Uint8List> _convertYUV420toJPEG(CameraImage image, int quality, int targetWidth) async {
    try {
      final int width = image.width;
      final int height = image.height;

      // Maintain aspect ratio
      final int targetHeight = (targetWidth * height / width).round();

      // Create an image buffer with proper color space
      final img.Image imgLib = img.Image(width: targetWidth, height: targetHeight);

      // Get plane data
      final yPlane = image.planes[0];
      final uPlane = image.planes[1];
      final vPlane = image.planes[2];

      final int yRowStride = yPlane.bytesPerRow;
      final int uvRowStride = uPlane.bytesPerRow;
      final int uvPixelStride = uPlane.bytesPerPixel!;

      // YUV to RGB conversion - implemented directly without external functions
      for (int y = 0; y < targetHeight; y++) {
        final sourceY = (y * height / targetHeight).floor();

        for (int x = 0; x < targetWidth; x++) {
          final sourceX = (x * width / targetWidth).floor();

          final int yIndex = sourceY * yRowStride + sourceX;

          // Calculate UV indices based on YUV420 format (half resolution for U and V)
          final int uvY = sourceY ~/ 2;
          final int uvX = sourceX ~/ 2;
          final int uvIndex = uvY * uvRowStride + uvX * uvPixelStride;

          // Check bounds to prevent index errors
          if (yIndex >= yPlane.bytes.length ||
              uvIndex >= uPlane.bytes.length ||
              uvIndex >= vPlane.bytes.length) {
            continue;
          }

          // Get YUV values with proper unsigned byte handling
          final int yValue = yPlane.bytes[yIndex] & 0xFF;
          final int uValue = uPlane.bytes[uvIndex] & 0xFF;
          final int vValue = vPlane.bytes[uvIndex] & 0xFF;

          // Standard YUV to RGB conversion formula
          // ITU-R recommendation BT.601 (formerly CCIR 601) standard
          int r = (yValue + 1.402 * (vValue - 128)).round();
          int g = (yValue - 0.344136 * (uValue - 128) - 0.714136 * (vValue - 128)).round();
          int b = (yValue + 1.772 * (uValue - 128)).round();

          // Clamp to valid RGB range
          r = r.clamp(0, 255);
          g = g.clamp(0, 255);
          b = b.clamp(0, 255);

          imgLib.setPixelRgb(x, y, r, g, b);
        }
      }

      // Apply correct rotation based on camera orientation
      final int sensorOrientation = widget.cameras[0].sensorOrientation;
      img.Image rotatedImage;
      switch (sensorOrientation) {
        case 90:
          rotatedImage = img.copyRotate(imgLib, angle: 90);
          break;
        case 180:
          rotatedImage = img.copyRotate(imgLib, angle: 180);
          break;
        case 270:
          rotatedImage = img.copyRotate(imgLib, angle: 270);
          break;
        default:
          rotatedImage = imgLib; // No rotation needed
      }

      // Ensure proper encoding with color preservation
      final List<int> jpegBytes = img.encodeJpg(rotatedImage, quality: quality);
      return Uint8List.fromList(jpegBytes);
    } catch (e) {
      print('Error in YUV conversion: $e');

      // Create a colored fallback image to verify color pipeline
      final img.Image imgLib = img.Image(width: 160, height: 120);
      // Add a colored pattern to verify color is working
      for (int y = 0; y < imgLib.height; y++) {
        for (int x = 0; x < imgLib.width; x++) {
          if ((x ~/ 20 + y ~/ 20) % 2 == 0) {
            imgLib.setPixelRgba(x, y, 255, 0, 0, 255); // Red
          } else {
            imgLib.setPixelRgba(x, y, 0, 0, 255, 255); // Blue
          }
        }
      }
      final List<int> jpegBytes = img.encodeJpg(imgLib, quality: quality);
      return Uint8List.fromList(jpegBytes);
    }
  }

// For examining image format to debug color issues
  void _printImageFormatDetails(CameraImage image) {
    print('\n------ Camera Image Format Details ------');
    print('Format Group: ${image.format.group}');
    print('Format Raw: ${image.format.raw}');
    print('Width: ${image.width}, Height: ${image.height}');
    print('Planes count: ${image.planes.length}');

    for (int i = 0; i < image.planes.length; i++) {
      print('Plane $i:');
      print('  Bytes per row: ${image.planes[i].bytesPerRow}');
      print('  Bytes per pixel: ${image.planes[i].bytesPerPixel}');
      print('  Height: ${image.planes[i].height}');
      print('  Width: ${image.planes[i].width}');
      print('  Bytes length: ${image.planes[i].bytes.length}');
      if (image.planes[i].bytes.length > 0) {
        print('  First few bytes: ${image.planes[i].bytes.sublist(0, math.min(10, image.planes[i].bytes.length))}');
      }
    }
    print('----------------------------------------\n');
  }


// Modified image processing function to try both methods
  Future<void> _processAndSendCameraImage(CameraImage image) async {
    try {
      // Dynamic quality adjustment
      final int qualityAdjusted = (JPEG_QUALITY * connectionQuality).round();
      final int widthAdjusted = (TARGET_WIDTH * connectionQuality).round();

      Uint8List bytes;

      // Try using the plugin method first
      try {
        bytes = await _convertYUV420toJPEG(image,
            qualityAdjusted > 20 ? qualityAdjusted : 20,
            widthAdjusted > 160 ? widthAdjusted : 160);
      } catch (e) {
        print('Plugin conversion failed, falling back to manual: $e');
        // Fall back to the fixed manual conversion
        bytes = await _convertYUV420toJPEG(image,
            qualityAdjusted > 20 ? qualityAdjusted : 20,
            widthAdjusted > 160 ? widthAdjusted : 160);
      }

      // Send to all connected clients
      bool successfullySent = false;
      for (var client in List.from(clients)) {
        try {
          client.add(bytes);
          successfullySent = true;

          // Update statistics
          framesSent++;
          totalBytesSent += bytes.length;
        } catch (e) {
          print('Error sending to client: $e');
          clients.remove(client);
        }
      }

      // Update UI if frame was sent successfully
      if (successfullySent && mounted) {
        setState(() {});
      }
    } catch (e) {
      print('Error processing camera image: $e');
    } finally {
      isProcessingFrame = false;
    }
  }
// Isolate function for better performance
  Uint8List _processImageInIsolate(Map<String, dynamic> params) {
    final int width = params['width'];
    final int height = params['height'];
    final int targetWidth = params['targetWidth'];
    final int targetHeight = params['targetHeight'];
    final int quality = params['quality'];
    final Uint8List yPlane = params['yPlane'];
    final Uint8List uPlane = params['uPlane'];
    final Uint8List vPlane = params['vPlane'];
    final int yRowStride = params['yRowStride'];
    final int uvRowStride = params['uvRowStride'];
    final int uvPixelStride = params['uvPixelStride'];
    final int orientation = params['orientation'];

    // Create image with the target size directly to avoid multiple resizes
    final img.Image imgLib = img.Image(width: targetWidth, height: targetHeight);

    // Improved YUV to RGB conversion - using integer math where possible
    // Look-up tables for faster conversion
    final List<int> yLookup = List<int>.generate(256, (i) => i);
    final List<int> rVLookup = List<int>.generate(256, (i) => (1.402 * (i - 128)).round());
    final List<int> gULookup = List<int>.generate(256, (i) => (0.344136 * (i - 128)).round());
    final List<int> gVLookup = List<int>.generate(256, (i) => (0.714136 * (i - 128)).round());
    final List<int> bULookup = List<int>.generate(256, (i) => (1.772 * (i - 128)).round());

    // Better sampling algorithm - bilinear interpolation for higher quality
    for (int y = 0; y < targetHeight; y++) {
      final double sourceYF = y * height / targetHeight;
      final int sourceY1 = sourceYF.floor();
      final int sourceY2 = math.min(sourceY1 + 1, height - 1);
      final double yWeight = sourceYF - sourceY1;

      for (int x = 0; x < targetWidth; x++) {
        final double sourceXF = x * width / targetWidth;
        final int sourceX1 = sourceXF.floor();
        final int sourceX2 = math.min(sourceX1 + 1, width - 1);
        final double xWeight = sourceXF - sourceX1;

        // Bilinear interpolation for Y values
        final int yIndex1 = sourceY1 * yRowStride + sourceX1;
        final int yIndex2 = sourceY1 * yRowStride + sourceX2;
        final int yIndex3 = sourceY2 * yRowStride + sourceX1;
        final int yIndex4 = sourceY2 * yRowStride + sourceX2;

        // Safe bounds checking
        if (math.max(yIndex1, math.max(yIndex2, math.max(yIndex3, yIndex4))) >= yPlane.length) {
          continue;
        }

        final int y1 = yPlane[yIndex1] & 0xFF;
        final int y2 = yPlane[yIndex2] & 0xFF;
        final int y3 = yPlane[yIndex3] & 0xFF;
        final int y4 = yPlane[yIndex4] & 0xFF;

        final int yValue = (y1 * (1 - xWeight) * (1 - yWeight) +
            y2 * xWeight * (1 - yWeight) +
            y3 * (1 - xWeight) * yWeight +
            y4 * xWeight * yWeight).round();

        // Get U and V values (subsampled, so divide by 2)
        final int uvY1 = (sourceY1 ~/ 2);
        final int uvX1 = (sourceX1 ~/ 2);

        final int uvIndex = uvY1 * uvRowStride + uvX1 * uvPixelStride;

        // Safe bounds checking
        if (uvIndex >= uPlane.length || uvIndex >= vPlane.length) {
          continue;
        }

        final int uValue = uPlane[uvIndex] & 0xFF;
        final int vValue = vPlane[uvIndex] & 0xFF;

        // Fast YUV to RGB conversion using lookup tables
        int r = (yValue + rVLookup[vValue]).clamp(0, 255);
        int g = (yValue - gULookup[uValue] - gVLookup[vValue]).clamp(0, 255);
        int b = (yValue + bULookup[uValue]).clamp(0, 255);

        imgLib.setPixelRgb(x, y, r, g, b);
      }
    }

    // Handle rotation based on sensor orientation
    img.Image rotatedImage;
    switch (orientation) {
      case 90:
        rotatedImage = img.copyRotate(imgLib, angle: 90);
        break;
      case 180:
        rotatedImage = img.copyRotate(imgLib, angle: 180);
        break;
      case 270:
        rotatedImage = img.copyRotate(imgLib, angle: 270);
        break;
      default:
        rotatedImage = imgLib; // No rotation needed
    }

    // Apply subtle image enhancement for better quality
    final img.Image enhancedImage = _enhanceImage(rotatedImage);

    // Encode with optimized quality
    final List<int> jpegBytes = img.encodeJpg(enhancedImage, quality: quality);
    return Uint8List.fromList(jpegBytes);
  }

// Image enhancement function for better visual quality
  img.Image _enhanceImage(img.Image image) {
    // Apply slight contrast enhancement
    return img.adjustColor(
      image,
      contrast: 1.1,
      saturation: 1.05,
      // Avoid excessive sharpening which can introduce noise
      exposure: 1.02,
    );
  }
  void connectToServer() async {
    final formKey = GlobalKey<FormState>();
    String serverIp = "192.168.43.1"; // Default hotspot IP
    int serverPort = 8080;

    // Show dialog to enter server details
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Connect to Server'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                decoration: InputDecoration(labelText: 'Server IP Address'),
                initialValue: serverIp,
                validator: (value) => value!.isEmpty ? 'Please enter IP address' : null,
                onSaved: (value) => serverIp = value!,
              ),
              TextFormField(
                decoration: InputDecoration(labelText: 'Port'),
                initialValue: '8080',
                keyboardType: TextInputType.number,
                validator: (value) => value!.isEmpty ? 'Please enter port' : null,
                onSaved: (value) => serverPort = int.parse(value!),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                formKey.currentState!.save();
                Navigator.pop(context);
                _connectToServer(serverIp, serverPort);
              }
            },
            child: Text('Connect'),
          ),
        ],
      ),
    );
  }

  void _connectToServer(String ip, int port) async {
    try {
      setState(() {
        isServer = false;
        framesReceived = 0;
        statisticsStartTime = DateTime.now();
      });

      // Connect to WebSocket server with compression enabled
      final uri = Uri.parse('ws://$ip:$port');

      // Add error handling for connection
      channel = IOWebSocketChannel.connect(
        uri,
        pingInterval: Duration(seconds: 5),
        protocols: ['permessage-deflate'], // Enable compression
      );

      print('Connecting to server at $uri');

      // Set a timeout for connection
      bool connectionEstablished = false;
      Timer connectionTimeout = Timer(Duration(seconds: 10), () {
        if (!connectionEstablished) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Connection timeout. Please check IP and port.')),
          );
          channel?.sink.close();
          setState(() {
            isConnected = false;
          });
        }
      });

      // Listen for incoming data
      channel!.stream.listen(
            (message) {
          connectionEstablished = true;
          if (!isConnected) {
            setState(() {
              isConnected = true;
            });
            print('Connected to server successfully');

            // Start ping measurement
            _startClientPing();
          }

          if (message is List<int> || message is Uint8List) {
            // Convert to Uint8List if needed
            final imageData = message is List<int>
                ? Uint8List.fromList(message)
                : message as Uint8List;

            if (imageData.length > 100) { // Threshold to identify image data vs location data
              setState(() {
                receivedImageData = imageData;
                framesReceived++;
              });
            } else if (imageData.length == 24) {
              // Binary location data
              ByteData byteData = ByteData.view(imageData.buffer);
              setState(() {
                remoteLocation = LocationData.fromMap({
                  'latitude': byteData.getFloat64(0),
                  'longitude': byteData.getFloat64(8),
                  'accuracy': byteData.getFloat64(16),
                });
              });
            }
          } else if (message is String) {
            if (message.startsWith('PING:')) {
              // Respond to ping
              channel!.sink.add('PONG:${message.substring(5)}');
            } else if (message.startsWith('PONG:')) {
              // Calculate latency
              try {
                final pingTime = int.parse(message.substring(5));
                final now = DateTime.now().millisecondsSinceEpoch;
                latencyMs = now - pingTime;

                // Update connection quality
                if (latencyMs < 50) {
                  connectionQuality = 1.0;
                } else if (latencyMs < 100) {
                  connectionQuality = 0.9;
                } else if (latencyMs < 200) {
                  connectionQuality = 0.7;
                } else if (latencyMs < 500) {
                  connectionQuality = 0.5;
                } else {
                  connectionQuality = 0.3;
                }

                setState(() {});
              } catch (e) {
                print('Error processing pong: $e');
              }
            } else if (message.startsWith('LOCATION:')) {
              final locationParts = message.substring(9).split(',');
              if (locationParts.length >= 2) {
                setState(() {
                  remoteLocation = LocationData.fromMap({
                    'latitude': double.parse(locationParts[0]),
                    'longitude': double.parse(locationParts[1]),
                    'accuracy': locationParts.length > 2 ? double.parse(locationParts[2]) : 0.0,
                  });
                });
              }
            }
          }
        },
        onDone: () {
          print('WebSocket connection closed');
          connectionTimeout.cancel();
          setState(() {
            isConnected = false;
          });
        },
        onError: (error) {
          print('WebSocket error: $error');
          connectionTimeout.cancel();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Connection error: $error')),
          );
          setState(() {
            isConnected = false;
          });
        },
      );

      // Send location updates
      locationTimer = Timer.periodic(Duration(milliseconds: LOCATION_INTERVAL_MS), (timer) {
        if (currentLocation != null && isConnected) {
          try {
            // Send location in binary format for efficiency
            ByteData data = ByteData(24); // 3 doubles at 8 bytes each
            data.setFloat64(0, currentLocation!.latitude ?? 0);
            data.setFloat64(8, currentLocation!.longitude ?? 0);
            data.setFloat64(16, currentLocation!.accuracy ?? 0);
            channel!.sink.add(Uint8List.view(data.buffer));
          } catch (e) {
            print('Error sending location: $e');
          }
        }
      });
    } catch (e) {
      print('Error connecting to server: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to connect to server: $e')),
      );
    }
  }

  void _startClientPing() {
    // Send ping every 2 seconds
    pingTimer = Timer.periodic(Duration(seconds: 2), (timer) {
      if (isConnected) {
        try {
          lastPingSent = DateTime.now();
          channel!.sink.add('PING:${lastPingSent!.millisecondsSinceEpoch}');
        } catch (e) {
          print('Error sending ping: $e');
        }
      }
    });
  }

  void _updateStatistics() {
    if (statisticsStartTime == null) return;

    final duration = DateTime.now().difference(statisticsStartTime!).inSeconds;
    if (duration <= 0) return;

    if (isServer) {
      // Calculate FPS and bandwidth
      final fps = framesSent / duration;
      final kbps = (totalBytesSent / 1024) / duration;

      print('Server stats - FPS: ${fps.toStringAsFixed(1)}, Bandwidth: ${kbps.toStringAsFixed(1)} KB/s');
    } else if (isConnected) {
      // Calculate received FPS
      final fps = framesReceived / duration;
      print('Client stats - FPS: ${fps.toStringAsFixed(1)}, Latency: $latencyMs ms');
    }
  }

  // Map Controller for interactivity
  final MapController _mapController = MapController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Sancim App'),
        actions: [
          if (isConnected)
            IconButton(
              icon: Icon(Icons.refresh),
              onPressed: () {
                if (isServer) {
                  if (!isStreaming) {
                    startStreaming();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Starting stream')),
                    );
                  } else {
                    // Restart stream
                    stopStreaming();
                    Future.delayed(Duration(milliseconds: 500), () {
                      startStreaming();
                    });
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Restarting stream')),
                    );
                  }
                }
              },
              tooltip: 'Restart Stream',
            ),
            // New bluetooth icon button
            IconButton(
              icon: Icon(isBtConnected ? Icons.bluetooth_connected : Icons.bluetooth),
              onPressed: isBtConnected ? disconnectFromArduino : scanForArduino,
              tooltip: isBtConnected ? "Disconnect Arduino" : "Connect Arduino",
            ),
        ],
      ),
      body: Stack(
        children: [
          // Main content
          Positioned.fill(
            child: isServer
                ? (isCameraInitialized
                ? FittedBox(
                  fit: BoxFit.cover, // Ensures the preview fills the screen
                  child: SizedBox(
                    width: MediaQuery.of(context).size.width,
                    height: MediaQuery.of(context).size.height,
                    child: CameraPreview(cameraController!),
                  ),
                )
                : Center(child:CircularProgressIndicator()))
                : (isConnected
                ? (receivedImageData != null
                ? Image.memory(
              receivedImageData!,
              fit: BoxFit.cover,
              gaplessPlayback: true, // Prevent flickering
              key: ValueKey(framesReceived), // Force refresh
            )
                : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 10),
                Text('Waiting for stream...'),
              ],
            ))
                : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('Not connected', style: TextStyle(fontSize: 18)),
                SizedBox(height: 20),
                ElevatedButton(
                  onPressed: startServer,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.wifi_tethering),
                      SizedBox(width: 8),
                      Text('Start as Server'),
                    ],
                  ),
                ),
                SizedBox(height: 10),
                ElevatedButton(
                  onPressed: connectToServer,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.connect_without_contact),
                      SizedBox(width: 8),
                      Text('Connect to Server'),
                    ],
                  ),
                ),
              ],
            )),
          ),

          // Map overlay
          if (!isServer && isConnected && remoteLocation != null)
            Positioned(
              left: 10,
              top: 10, // Account for status bar
              child: Container(
                // Dynamic width based on screen size (30% of screen width)
                width: MediaQuery.of(context).size.width * 0.3,
                // Dynamic height with min/max constraints
                height: math.min(
                  MediaQuery.of(context).size.height * 0.25, // 25% of screen height
                  200, // Maximum height
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(10),
                  // Add a subtle shadow for better visibility
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 4,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      center: LatLng(
                        remoteLocation!.latitude!,
                        remoteLocation!.longitude!,
                      ),
                      zoom: 15.0,
                      maxZoom: 18.0,
                      minZoom: 10.0,
                      // Disable interactions if you want a static map display
                      // interactionOptions: InteractionOptions(
                      //   flags: InteractiveFlag.none,
                      // ),
                    ),
                    children: [
                      // OpenStreetMap tiles
                      TileLayer(
                        urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                        subdomains: ['a', 'b', 'c'],
                      ),
                      // Marker for the server's location
                      MarkerLayer(
                        markers: [
                          Marker(
                            width: 40.0,
                            height: 40.0,
                            point: LatLng(
                              remoteLocation!.latitude!,
                              remoteLocation!.longitude!,
                            ),
                            builder: (ctx) => Icon(
                              Icons.location_pin,
                              color: Colors.red,
                              size: 40.0,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Connection quality indicator overlay
          if (isConnected)
            Positioned(
              top: 10,
              right: 10,
              child: Container(
                padding: EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _getConnectionIcon(connectionQuality),
                      color: _getConnectionColor(connectionQuality),
                      size: 24,
                    ),
                    SizedBox(width: 4),
                    Text(
                      '$latencyMs ms',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
      ),
      bottomNavigationBar: BottomAppBar(
        color: Colors.blue,
        child: Container(
          height: 60,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    isConnected ? Icons.link : Icons.link_off,
                    color: isConnected ? Colors.green : Colors.red,
                  ),
                  Text(
                    isConnected ? 'Connected' : 'Disconnected',
                    style: TextStyle(color: Colors.white),
                  ),
                ],
              ),
              if (isServer)
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      isStreaming ? Icons.videocam : Icons.videocam_off,
                      color: isStreaming ? Colors.green : Colors.red,
                    ),
                    Text(
                      isStreaming ? 'Streaming' : 'Not Streaming',
                      style: TextStyle(color: Colors.white),
                    ),
                  ],
                ),
              if (isConnected)
                IconButton(
                  icon: Icon(Icons.close, color: Colors.white),
                  onPressed: () {
                    // Disconnect logic
                    if (isServer) {
                      stopStreaming();
                      clients.forEach((client) => client.close());
                      clients.clear();
                      server?.close();
                    } else {
                      channel?.sink.close();
                    }
                    setState(() {
                      isConnected = false;
                    });
                  },
                  tooltip: 'Disconnect',
                ),
            ],
          ),
        ),
      ),
      floatingActionButton: isServer && isConnected && isCameraInitialized
          ? FloatingActionButton(
        onPressed: () {
          if (isStreaming) {
            stopStreaming();
          } else {
            startStreaming();
          }
        },
        child: Icon(isStreaming ? Icons.stop : Icons.play_arrow),
        tooltip: isStreaming ? 'Stop Streaming' : 'Start Streaming',
      )
          : null,
    );
  }

  // Helper function to get connection icon based on quality
  IconData _getConnectionIcon(double quality) {
    if (quality > 0.8) return Icons.signal_cellular_alt;
    if (quality > 0.5) return Icons.signal_cellular_alt_2_bar;
    if (quality > 0.3) return Icons.signal_cellular_alt_1_bar;
    return Icons.signal_cellular_connected_no_internet_0_bar;
  }

  // Helper function to get connection color based on quality
  Color _getConnectionColor(double quality) {
    if (quality > 0.8) return Colors.green;
    if (quality > 0.5) return Colors.yellow;
    if (quality > 0.3) return Colors.orange;
    return Colors.red;
  }

  // Calculate distance between two coordinates using Haversine formula
  double _calculateDistance(double lat1, double lon1, double lat2, double lon2) {
    const double earthRadius = 6371000; // meters

    // Convert from degrees to radians
    final dLat = _toRadians(lat2 - lat1);
    final dLon = _toRadians(lon2 - lon1);

    // Haversine formula
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRadians(lat1)) * math.cos(_toRadians(lat2)) *
            math.sin(dLon / 2) * math.sin(dLon / 2);

    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));

    return earthRadius * c; // Distance in meters
  }

  double _toRadians(double degree) {
    return degree * math.pi / 180;
  }
}

// Add a helper class for direction calculation and guidance
class NavigationHelper {
  // Calculate bearing between two points
  static double calculateBearing(double lat1, double lon1, double lat2, double lon2) {
    final double dLon = _toRadians(lon2 - lon1);

    final double y = math.sin(dLon) * math.cos(_toRadians(lat2));
    final double x = math.cos(_toRadians(lat1)) * math.sin(_toRadians(lat2)) -
        math.sin(_toRadians(lat1)) * math.cos(_toRadians(lat2)) * math.cos(dLon);

    double bearing = math.atan2(y, x);
    bearing = _toDegrees(bearing);
    bearing = (bearing + 360) % 360; // Normalize to 0-360

    return bearing;
  }

  // Convert direction in degrees to cardinal direction
  static String getCardinalDirection(double bearing) {
    const directions = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW', 'N'];
    return directions[(bearing / 45).round() % 8];
  }

  // Get navigation instruction based on bearing and distance
  static String getNavigationInstruction(double bearing, double distance) {
    final String direction = getCardinalDirection(bearing);

    if (distance < 10) {
      return "You have reached the destination";
    } else if (distance < 50) {
      return "Very close! Continue $direction";
    } else if (distance < 200) {
      return "Head $direction for ${distance.round()} meters";
    } else {
      return "Go $direction for about ${(distance / 100).round() / 10} km";
    }
  }

  // Utility function: convert radians to degrees
  static double _toDegrees(double radians) {
    return radians * 180 / math.pi;
  }

  // Utility function: convert degrees to radians
  static double _toRadians(double degrees) {
    return degrees * math.pi / 180;
  }
}

// Implement a battery-efficient location manager
class LocationManager {
  final Location _location = Location();
  LocationData? _lastLocation;

  // Callbacks
  Function(LocationData)? onLocationChanged;

  // Configuration
  bool _isHighAccuracy = false;
  int _updateIntervalMs = 3000;

  Future<bool> initialize() async {
    // Check if location service is enabled
    bool serviceEnabled = await _location.serviceEnabled();
    if (!serviceEnabled) {
      serviceEnabled = await _location.requestService();
      if (!serviceEnabled) {
        return false;
      }
    }

    /*
    // Check permissions
    PermissionStatus permissionStatus = await _location.hasPermission();
    if (permissionStatus == PermissionStatus.denied) {
      permissionStatus = await _location.requestPermission();
      if (permissionStatus != PermissionStatus.granted) {
        return false;
      }
    }*/

    // Configure location service
    await _configureLocationService();

    // Start listening for updates
    _location.onLocationChanged.listen(_handleLocationUpdate);

    return true;
  }

  Future<void> _configureLocationService() async {
    await _location.changeSettings(
      accuracy: _isHighAccuracy ? LocationAccuracy.high : LocationAccuracy.balanced,
      interval: _updateIntervalMs,
      distanceFilter: _isHighAccuracy ? 5 : 20, // meters
    );
  }

  void _handleLocationUpdate(LocationData locationData) {
    _lastLocation = locationData;
    onLocationChanged?.call(locationData);
  }

  // Set accuracy mode based on battery and needs
  void setHighAccuracyMode(bool highAccuracy) {
    if (_isHighAccuracy != highAccuracy) {
      _isHighAccuracy = highAccuracy;
      _configureLocationService();
    }
  }

  // Adjust update interval for battery optimization
  void setUpdateInterval(int intervalMs) {
    if (_updateIntervalMs != intervalMs) {
      _updateIntervalMs = intervalMs;
      _configureLocationService();
    }
  }

  // Get last known location
  LocationData? getLastLocation() {
    return _lastLocation;
  }

  // Request a one-time location update
  Future<LocationData?> getOneTimeLocation() async {
    try {
      return await _location.getLocation();
    } catch (e) {
      print('Error getting one-time location: $e');
      return null;
    }
  }

  // Request a high-accuracy location (useful when approaching destination)
  Future<LocationData?> getHighAccuracyLocation() async {
    // Save current settings
    final bool previousHighAccuracy = _isHighAccuracy;

    // Temporarily switch to high accuracy
    await _location.changeSettings(
      accuracy: LocationAccuracy.high,
      interval: 1000,
      distanceFilter: 1, // meter
    );

    // Get location with high accuracy
    LocationData? locationData;
    try {
      locationData = await _location.getLocation();
    } catch (e) {
      print('Error getting high-accuracy location: $e');
    }

    // Restore previous settings
    if (!previousHighAccuracy) {
      await _configureLocationService();
    }

    return locationData;
  }

  // Cleanup
  void dispose() {
    // No explicit dispose needed as the location service handles it
  }
}