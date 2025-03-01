/*import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_tts/flutter_tts.dart';

class BluetoothScreen extends StatefulWidget {
  @override
  _BluetoothScreenState createState() => _BluetoothScreenState();
}

class _BluetoothScreenState extends State<BluetoothScreen> {
  FlutterBluePlus flutterBlue = FlutterBluePlus.instance;
  FlutterTts flutterTts = FlutterTts();
  String sensorData = "No Data";

  void connectToArduino() async {
    flutterBlue.startScan(timeout: Duration(seconds: 4));
    flutterBlue.scanResults.listen((results) {
      for (var result in results) {
        if (result.device.name == "ArduinoUno") { // Change this to your module name
          result.device.connect();
          listenForData(result.device);
        }
      }
    });
  }

  void listenForData(BluetoothDevice device) {
    device.services.listen((services) {
      for (var service in services) {
        for (var characteristic in service.characteristics) {
          characteristic.setNotifyValue(true);
          characteristic.value.listen((value) {
            setState(() {
              sensorData = String.fromCharCodes(value);
              flutterTts.speak(sensorData); // Convert to voice
            });
          });
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Sensor Alerts')),
      body: Center(child: Text(sensorData, style: TextStyle(fontSize: 22))),
      floatingActionButton: FloatingActionButton(
        onPressed: connectToArduino,
        child: Icon(Icons.bluetooth),
      ),
    );
  }
}*/
