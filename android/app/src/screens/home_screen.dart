import 'package:flutter/material.dart';
//import '../bluetooth/bluetooth_screen.dart';
import '../gps/gps_screen.dart';
import '../camera/camera_screen.dart';
//import '../alerts/sos_screen.dart';

class HomeScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Visually Impaired Assistance')),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          //HomeButton(title: 'Sensor Alerts', screen: BluetoothScreen()),
          HomeButton(title: 'GPS Tracking', screen: GPSScreen()),
          HomeButton(title: 'Live Camera Feed', screen: CameraScreen()),
          //HomeButton(title: 'Emergency SOS', screen: SOSScreen()),
        ],
      ),
    );
  }
}

class HomeButton extends StatelessWidget {
  final String title;
  final Widget screen;
  HomeButton({required this.title, required this.screen});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(10.0),
      child: ElevatedButton(
        onPressed: () => Navigator.push(
            context, MaterialPageRoute(builder: (context) => screen)),
        child: Text(title, style: TextStyle(fontSize: 18)),
      ),
    );
  }
}
