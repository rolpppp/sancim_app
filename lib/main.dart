import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'package:location/location.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  runApp(MyApp(cameras: cameras));
}

class MyApp extends StatelessWidget {
  final List<CameraDescription> cameras;

  const MyApp({Key? key, required this.cameras}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Wi-Fi Livestream with GPS',
      theme: ThemeData(primarySwatch: Colors.blue),
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

class _HomePageState extends State<HomePage> {
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

  // Location
  Location location = Location();
  LocationData? currentLocation;
  Timer? locationTimer;
  Timer? streamingTimer;

  // For receiver
  Uint8List? receivedImageData;
  LocationData? remoteLocation;

  @override
  void initState() {
    super.initState();
    checkPermissions();
  }

  @override
  void dispose() {
    cameraController?.dispose();
    locationTimer?.cancel();
    streamingTimer?.cancel();
    channel?.sink.close();
    server?.close();
    super.dispose();
  }

  void checkPermissions() async {
    // Check location permission
    bool serviceEnabled = await location.serviceEnabled();
    if (!serviceEnabled) {
      serviceEnabled = await location.requestService();
      if (!serviceEnabled) return;
    }

    PermissionStatus permissionStatus = await location.hasPermission();
    if (permissionStatus == PermissionStatus.denied) {
      permissionStatus = await location.requestPermission();
      if (permissionStatus != PermissionStatus.granted) return;
    }

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

    cameraController = CameraController(
      widget.cameras[0],
      ResolutionPreset.medium, // Higher resolution possible with Wi-Fi
      enableAudio: false,
    );

    try {
      await cameraController!.initialize();

      // Important: set this to true only after successful initialization
      setState(() {
        isCameraInitialized = true;
      });

      // Start streaming if this is the server
      if (isServer) {
        startStreaming();
      }
    } catch (e) {
      print('Error initializing camera: $e');
    }
  }

  void startServer() async {
    try {
      setState(() {
        isServer = true;
      });

      // Get hotspot IP address
      final info = NetworkInfo();
      final wifiIP = await info.getWifiIP();
      ipAddress = wifiIP ?? "192.168.43.1"; // Default hotspot IP

      // Start WebSocket server
      server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      print('Server started at $ipAddress:$port');

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
        setState(() {
          clients.add(ws);
          isConnected = true;
        });

        // Handle client connection established - restart streaming if needed
        if (isServer && isCameraInitialized && clients.isNotEmpty && streamingTimer == null) {
          startStreaming();
        }

        // Listen for messages from client
        ws.listen((message) {
          if (message is String && message.startsWith('LOCATION:')) {
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
        }, onDone: () {
          print('Client disconnected');
          clients.remove(ws);
          if (clients.isEmpty) {
            setState(() {
              isConnected = false;
            });
          }
        }, onError: (error) {
          print('WebSocket error: $error');
          clients.remove(ws);
          if (clients.isEmpty) {
            setState(() {
              isConnected = false;
            });
          }
        });
      });

      // Start sending location updates
      locationTimer = Timer.periodic(Duration(seconds: 3), (timer) {
        if (currentLocation != null && clients.isNotEmpty) {
          for (var client in clients) {
            try {
              client.add('LOCATION:${currentLocation!.latitude},${currentLocation!.longitude},${currentLocation!.accuracy}');
            } catch (e) {
              print('Error sending location: $e');
            }
          }
        }
      });
    } catch (e) {
      print('Error starting server: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error starting server: $e')),
      );
    }
  }

  void startStreaming() {
    if (cameraController == null || !cameraController!.value.isInitialized) {
      print('Camera not initialized');
      return;
    }

    // Cancel existing timer if any
    streamingTimer?.cancel();

    streamingTimer = Timer.periodic(Duration(milliseconds: 200), (timer) async {
      if (!isServer || clients.isEmpty) {
        timer.cancel();
        streamingTimer = null;
        print('Streaming stopped: isServer=$isServer, clients=${clients.length}');
        return;
      }

      try {
        XFile image = await cameraController!.takePicture();
        final bytes = await image.readAsBytes();

        // Prevent memory issues by reducing file size
        img.Image? decodedImage = img.decodeImage(bytes);
        if (decodedImage != null) {
          // Resize image to reduce data size
          img.Image resizedImage = img.copyResize(
            decodedImage,
            width: 320,  // Reduced width for better performance
            height: (320 * decodedImage.height / decodedImage.width).round(),
          );

          // Compress image
          List<int> compressedBytes = img.encodeJpg(resizedImage, quality: 65);

          print('Frame captured and processed: ${compressedBytes.length} bytes');

          // Send to all connected clients
          for (var client in List.from(clients)) { // Use a copy to avoid concurrent modification
            try {
              client.add(compressedBytes);
            } catch (e) {
              print('Error sending to client: $e');
              clients.remove(client);
            }
          }
        }
      } catch (e) {
        print('Error in streaming: $e');
      }
    });
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
      });

      // Connect to WebSocket server
      final uri = Uri.parse('ws://$ip:$port');

      // Add error handling for connection
      channel = IOWebSocketChannel.connect(
        uri,
        pingInterval: Duration(seconds: 5),
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
          }

          if (message is List<int>) {
            print('Received frame: ${message.length} bytes');
            setState(() {
              receivedImageData = Uint8List.fromList(message);
            });
          } else if (message is String && message.startsWith('LOCATION:')) {
            print('Received location update: $message');
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
      locationTimer = Timer.periodic(Duration(seconds: 3), (timer) {
        if (currentLocation != null && isConnected) {
          try {
            channel!.sink.add('LOCATION:${currentLocation!.latitude},${currentLocation!.longitude},${currentLocation!.accuracy}');
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
                  if (streamingTimer == null) {
                    startStreaming();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Restarting stream')),
                    );
                  }
                }
              },
              tooltip: 'Restart Stream',
            ),
        ],
      ),
      body: Stack(
        children: [
          Center(
            child: isServer
                ? (isCameraInitialized
                ? CameraPreview(cameraController!)
                : CircularProgressIndicator())
                : (isConnected
                ? (receivedImageData != null
                ? Image.memory(receivedImageData!)
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
                  child: Text('Start as Server'),
                ),
                SizedBox(height: 10),
                ElevatedButton(
                  onPressed: connectToServer,
                  child: Text('Connect as Client'),
                ),
              ],
            )),
          ),

          // GPS tracking widget overlay
          if (currentLocation != null)
            Positioned(
              top: 20,
              right: 20,
              child: buildGpsWidget(),
            ),

          // Connection status overlay
          if (isConnected)
            Positioned(
              bottom: 20,
              right: 20,
              child: Container(
                padding: EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.7),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.wifi, color: Colors.white),
                    SizedBox(width: 4),
                    Text(
                      isServer
                          ? 'Server: ${clients.length} client(s) connected'
                          : 'Connected to server',
                      style: TextStyle(color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget buildGpsWidget() {
    return Container(
      width: 150,
      padding: EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('GPS Tracking',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          Divider(color: Colors.white30),
          if (currentLocation != null) ...[
            Text('Your Location:',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
            Text('Lat: ${currentLocation!.latitude!.toStringAsFixed(6)}',
              style: TextStyle(color: Colors.white),
            ),
            Text('Lng: ${currentLocation!.longitude!.toStringAsFixed(6)}',
              style: TextStyle(color: Colors.white),
            ),
          ],
          if (remoteLocation != null) ...[
            SizedBox(height: 8),
            Text('Remote Location:',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
            Text('Lat: ${remoteLocation!.latitude!.toStringAsFixed(6)}',
              style: TextStyle(color: Colors.white),
            ),
            Text('Lng: ${remoteLocation!.longitude!.toStringAsFixed(6)}',
              style: TextStyle(color: Colors.white),
            ),
            if (currentLocation != null)
              Text('Distance: ${_calculateDistance(currentLocation!, remoteLocation!).toStringAsFixed(2)} km',
                style: TextStyle(color: Colors.greenAccent),
              ),
          ],
        ],
      ),
    );
  }

  double _calculateDistance(LocationData loc1, LocationData loc2) {
    const R = 6371.0; // Earth radius in km
    final lat1 = loc1.latitude! * (math.pi / 180);
    final lat2 = loc2.latitude! * (math.pi / 180);
    final dLat = (loc2.latitude! - loc1.latitude!) * (math.pi / 180);
    final dLon = (loc2.longitude! - loc1.longitude!) * (math.pi / 180);

    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) * math.cos(lat2) *
            math.sin(dLon / 2) * math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));

    return R * c;
  }
}