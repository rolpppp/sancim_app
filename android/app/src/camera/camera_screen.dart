import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class CameraScreen extends StatefulWidget {
  @override
  _CameraScreenState createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  VideoPlayerController? controller;

  void initializeCamera() {
    controller = VideoPlayerController.network('http://192.168.0.100:8080/video')..initialize().then((_) {
      setState(() {});
      controller!.play();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Live Camera Feed')),
      body: controller == null ? Text("Start Stream") : VideoPlayer(controller!),
      floatingActionButton: FloatingActionButton(
        onPressed: initializeCamera,
        child: Icon(Icons.videocam),
      ),
    );
  }
}
