import 'package:flutter/material.dart';
import 'sensor_page.dart'; // For Sensor Detection & Alerts
import 'gps_page.dart'; // For GPS Tracking
import 'camera_page.dart'; // For Live Camera Feed
import 'sos_page.dart'; // For Emergency Alert System

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Visually Impaired Assistance',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Visually Impaired Assistance'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => SensorPage()),
                );
              },
              child: Text('Sensor Detection & Alerts'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => GpsPage()),
                );
              },
              child: Text('GPS Tracking & Live Location'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => CameraPage()),
                );
              },
              child: Text('Live Camera Feed'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => SosPage()),
                );
              },
              child: Text('Emergency Alert System'),
            ),
          ],
        ),
      ),
    );
  }
}