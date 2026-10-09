/// Configure the hospital endpoint explicitly; localhost belongs to the device.
const hubUrl = String.fromEnvironment('HUB_URL');
const hubToken = String.fromEnvironment('HUB_TOKEN');

Uri hubEndpoint(String base, String path) {
  final uri = Uri.tryParse(base);
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      !['', '/'].contains(uri.path)) {
    throw ArgumentError('Configure HUB_URL with the hospital LAN origin');
  }
  return uri.resolve(path);
}

Map<String, String> hubHeaders({String token = hubToken}) => {
  'Content-Type': 'application/json',
  if (token.isNotEmpty) 'Authorization': 'Bearer $token',
};
