// Reads which build the web host currently serves, and reloads the page.
// Conditional export: a real implementation in the browser, inert elsewhere.
export 'web_deploy_version_io.dart'
    if (dart.library.js_interop) 'web_deploy_version_web.dart';
