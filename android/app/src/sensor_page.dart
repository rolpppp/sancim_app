import 'package:flutter/material.dart';
import 'package:flutter_blue/flutter_blue.dart';

class SensorPage extends StatefulWidget {
  @override
  _SensorPageState createState() => _SensorPageState();
}

class _SensorPageState extends State<SensorPage> {
  FlutterBlue flutterBlue = FlutterBlue.instance;
  BluetoothDevice? arduinoDevice;

  void _connectToArduino() async {
    flutterBlue.startScan(timeout: Duration(seconds: 4));
    flutterBlue.scanResults.listen((results) {
      for (ScanResult result in results) {
        if (result.device.name == 'Arduino') {
          setState(() {
            arduinoDevice = result.device;
          });
          flutterBlue.stopScan();
          break;
        }
      }
    });

    if (arduinoDevice != null) {
      await arduinoDevice!.connect();
      print('Connected to Arduino');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Sensor Detection & Alerts'),
      ),
      body: Center(
        child: ElevatedButton(
          onPressed: _connectToArduino,
          child: Text('Connect to Arduino'),
        ),
      ),
    );
  }
}
