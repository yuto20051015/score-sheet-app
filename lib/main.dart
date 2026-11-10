import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'app_info.dart';
import 'firebase_options.dart';
import 'screens/score_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const SoftTennisApp());
}

class SoftTennisApp extends StatelessWidget {
  const SoftTennisApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.green,
        scaffoldBackgroundColor: const Color(0xFFF4F7F2),
      ),
      home: const ScoreScreen(),
    );
  }
}
