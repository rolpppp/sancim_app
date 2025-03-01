import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:firebase_database/firebase_database.dart';

class GPSScreen extends StatefulWidget {
  @override
  _GPSScreenState createState() => _GPSScreenState();
}

class _GPSScreenState extends State<GPSScreen> {
  Position? position;
  DatabaseReference dbRef = FirebaseDatabase.instance.ref('user_location');

  void updateLocation() async {
    position = await Geolocator.getCurrentPosition();
    dbRef.set({'latitude': position!.latitude, 'longitude': position!.longitude});
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('GPS Tracking')),
      body: Center(
        child: position == null
            ? Text("Press the button to get location")
            : Text("Lat: ${position!.latitude}, Lng: ${position!.longitude}"),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: updateLocation,
        child: Icon(Icons.location_on),
      ),
    );
  }
}
