import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:google_fonts/google_fonts.dart';
import 'constants.dart';
import 'auth_gate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
  runApp(const PublicFeedApp());
}

class PublicFeedApp extends StatelessWidget {
  const PublicFeedApp({super.key});

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        final Color seed = const Color(0xFF6750A4); // fallback
        final light = lightDynamic ??
            ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.light);
        final dark = darkDynamic ??
            ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark);

        ThemeData base(ColorScheme cs) => ThemeData(
              colorScheme: cs,
              useMaterial3: true,
              textTheme: GoogleFonts.interTextTheme().apply(
                bodyColor: cs.onSurface,
                displayColor: cs.onSurface,
              ),
              appBarTheme: const AppBarTheme(centerTitle: false, elevation: 0),
              scaffoldBackgroundColor: cs.surface,
              cardTheme: CardThemeData(
                elevation: 1,
                margin: const EdgeInsets.all(8),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
              ),
              inputDecorationTheme: const InputDecorationTheme(
                filled: true,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(12))),
              ),
            );

        return MaterialApp(
          title: 'Supa Public Feed',
          debugShowCheckedModeBanner: false,
          theme: base(light),
          darkTheme: base(dark),
          home: const AuthGate(),
        );
      },
    );
  }
}
