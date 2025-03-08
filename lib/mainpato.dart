import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_tts/flutter_tts.dart';

class BluetoothScreen extends StatefulWidget {
  @override
  _BluetoothScreenState createState() => _BluetoothScreenState();
}

class _BluetoothScreenState extends State<BluetoothScreen> {
  final FlutterBluePlus flutterBlue = FlutterBluePlus();
  final FlutterTts flutterTts = FlutterTts();
  BluetoothDevice? connectedDevice;
  bool isConnected = false;

  @override
  void initState() {
    super.initState();
    flutterTts.setLanguage("en-US");
  }

  void scanForDevices() {
    // Start scanning
    FlutterBluePlus.startScan(timeout: Duration(seconds: 10));

    // Listen to scan results
    FlutterBluePlus.scanResults.listen((results) {
      for (ScanResult result in results) {
        print('Found device: ${result.device.name} (${result.device.id})');
        if (result.device.name == "HC-05" || result.device.name == "HC-06") {
          // Stop scanning when the desired device is found
          FlutterBluePlus.stopScan();
          connectToDevice(result.device);
          break;
        }
      }
    });
  }

  void connectToDevice(BluetoothDevice device) async {
    // Connect to the device
    await device.connect();
    setState(() {
      connectedDevice = device;
      isConnected = true;
    });
    print('Connected to ${device.name}');

    // Discover services
    List<BluetoothService> services = await device.discoverServices();
    for (BluetoothService service in services) {
      print('Service: ${service.uuid}');

      // Discover characteristics
      for (BluetoothCharacteristic characteristic in service.characteristics) {
        print('Characteristic: ${characteristic.uuid}');

        // Listen for notifications (if supported)
        if (characteristic.properties.notify) {
          await characteristic.setNotifyValue(true);
          characteristic.value.listen((data) {
            String message = String.fromCharCodes(data);
            print('Received: $message'); // Print received data to the terminal
            // Convert the message to speech
            _speakMessage(message);
          });
        }
      }
    }
  }

  Future<void> _speakMessage(String message) async {
    await flutterTts.speak(message);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Bluetooth Connection'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed: scanForDevices,
              child: Text('Scan for Devices'),
            ),
            SizedBox(height: 20),
            Text(
              isConnected
                  ? 'Connected to ${connectedDevice?.name}'
                  : 'Not Connected',
              style: TextStyle(
                color: isConnected ? Colors.green : Colors.red,
                fontSize: 18,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
