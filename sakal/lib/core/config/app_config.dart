class AppConfig {
  static const String appName     = 'SAKAL ERP';
  static const String companyName = 'Rigevedam Innovations';
  static const String appTagline  = 'Sampurna — Complete Business Solution';
  static const String appVersion  = '1.0.0';

  // Supabase — anon key is safe to embed (it is the public key, protected by RLS).
  // When deploying on-premise, replace restBaseUrl with the local PostgREST URL.
  static const String supabaseUrl     = 'https://krygednbejwjuzlmmljn.supabase.co';
  static const String supabaseAnonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9'
      '.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImtyeWdlZG5iZWp3anV6bG1tbGpuIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODE0OTg1MDQsImV4cCI6MjA5NzA3NDUwNH0'
      '.yOWmf5r8KY9PfvSvW-UYGSrgWSjgMYptPWxVBtYeJ2Q';
  static const String restBaseUrl = '$supabaseUrl/rest/v1';

  static const String localDbName    = 'sakal_erp.db';
  static const int    localDbVersion = 1;
}
