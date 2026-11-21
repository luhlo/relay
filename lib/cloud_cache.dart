import 'cloud_cache_types.dart';
import 'cloud_cache_native.dart'
    if (dart.library.js_interop) 'cloud_cache_web.dart'
    as platform;

export 'cloud_cache_types.dart';

CloudCache createCloudCache() => platform.createCloudCache();
final CloudCache defaultCloudCache = createCloudCache();
