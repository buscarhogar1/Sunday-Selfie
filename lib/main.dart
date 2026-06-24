import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'dart:convert';

import 'package:app_links/app_links.dart';
import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as image_lib;
import 'package:image_picker/image_picker.dart' as image_picker;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'firebase_options.dart';

final GlobalKey<NavigatorState> sundayNavigatorKey =
    GlobalKey<NavigatorState>();
const MethodChannel foregroundNotificationChannel = MethodChannel(
  'sunday_selfie/foreground_notifications',
);
const MethodChannel mediaSaverChannel = MethodChannel(
  'sunday_selfie/media_saver',
);

void logDebug(String message) {
  if (kDebugMode) {
    debugPrint(message);
  }
}

class LocalPhotoCache {
  LocalPhotoCache._();

  static final LocalPhotoCache instance = LocalPhotoCache._();

  final Map<String, Future<File?>> _inFlightDownloads = {};
  final Map<String, File> _readyFiles = {};
  Directory? _cacheDirectory;

  bool get isSupported =>
      !kIsWeb &&
      (Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isMacOS ||
          Platform.isLinux ||
          Platform.isWindows);

  Future<Directory?> _directory() async {
    if (!isSupported) return null;
    final cachedDirectory = _cacheDirectory;
    if (cachedDirectory != null) return cachedDirectory;

    try {
      final documentsDirectory = await getApplicationDocumentsDirectory();
      final directory = Directory(
        '${documentsDirectory.path}/sunday_photo_cache',
      );
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      _cacheDirectory = directory;
      return directory;
    } catch (error) {
      logDebug('No se pudo abrir la caché local de fotos: $error');
      return null;
    }
  }

  String _fileNameForUrl(String url, String variant) {
    final digest = sha1.convert(utf8.encode(url.trim())).toString();
    return '${variant}_$digest.img';
  }

  Future<File?> getOrDownload(String url, {required String variant}) async {
    final trimmedUrl = url.trim();
    if (trimmedUrl.isEmpty) return null;

    final directory = await _directory();
    if (directory == null) return null;

    final key = '$variant|$trimmedUrl';
    final readyFile = _readyFiles[key];
    if (readyFile != null) {
      if (await readyFile.exists() && await readyFile.length() > 0) {
        return readyFile;
      }
      _readyFiles.remove(key);
    }

    final file = File(
      '${directory.path}/${_fileNameForUrl(trimmedUrl, variant)}',
    );
    if (await file.exists()) {
      if (await file.length() > 0) {
        _readyFiles[key] = file;
        return file;
      }
      await file.delete();
    }

    final existingDownload = _inFlightDownloads[key];
    if (existingDownload != null) return existingDownload;

    final download = _downloadToFile(trimmedUrl, file);
    _inFlightDownloads[key] = download;
    try {
      final downloadedFile = await download;
      if (downloadedFile != null) {
        _readyFiles[key] = downloadedFile;
      }
      return downloadedFile;
    } finally {
      _inFlightDownloads.remove(key);
    }
  }

  Future<void> prefetch(String? url, {required String variant}) async {
    final trimmedUrl = url?.trim();
    if (trimmedUrl == null || trimmedUrl.isEmpty) return;
    try {
      await getOrDownload(trimmedUrl, variant: variant);
    } catch (_) {
      // Best-effort warming only; the visible widget will handle errors.
    }
  }

  Future<File?> _downloadToFile(String url, File file) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return null;

    final tempFile = File('${file.path}.download');
    final httpClient = HttpClient();
    try {
      final request = await httpClient.getUrl(uri);
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }

      final bytes = await consolidateHttpClientResponseBytes(response);
      await tempFile.writeAsBytes(bytes, flush: true);
      if (await file.exists()) await file.delete();
      await tempFile.rename(file.path);
      return file;
    } catch (error) {
      logDebug('No se pudo descargar la foto en caché: $error');
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
      return null;
    } finally {
      httpClient.close(force: true);
    }
  }

  Future<int> clear() async {
    final directory = await _directory();
    if (directory == null || !await directory.exists()) return 0;

    var deletedCount = 0;
    await for (final entity in directory.list(followLinks: false)) {
      try {
        if (entity is File) {
          await entity.delete();
          deletedCount += 1;
        } else if (entity is Directory) {
          await entity.delete(recursive: true);
          deletedCount += 1;
        }
      } catch (error) {
        logDebug('No se pudo borrar un archivo de caché: $error');
      }
    }

    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    _readyFiles.clear();
    return deletedCount;
  }
}

class CachedRemoteImage extends StatefulWidget {
  final String imageUrl;
  final String cacheVariant;
  final BoxFit fit;
  final double? width;
  final double? height;
  final AlignmentGeometry alignment;
  final FilterQuality filterQuality;
  final bool gaplessPlayback;
  final String? semanticLabel;
  final Widget? loadingWidget;
  final Widget? errorWidget;

  const CachedRemoteImage({
    super.key,
    required this.imageUrl,
    required this.cacheVariant,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.alignment = Alignment.center,
    this.filterQuality = FilterQuality.high,
    this.gaplessPlayback = false,
    this.semanticLabel,
    this.loadingWidget,
    this.errorWidget,
  });

  @override
  State<CachedRemoteImage> createState() => _CachedRemoteImageState();
}

class _CachedRemoteImageState extends State<CachedRemoteImage> {
  Future<File?>? fileFuture;

  @override
  void initState() {
    super.initState();
    configureFuture();
  }

  @override
  void didUpdateWidget(covariant CachedRemoteImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl ||
        oldWidget.cacheVariant != widget.cacheVariant) {
      configureFuture();
    }
  }

  void configureFuture() {
    final trimmedUrl = widget.imageUrl.trim();
    fileFuture = trimmedUrl.isEmpty
        ? null
        : LocalPhotoCache.instance.getOrDownload(
            trimmedUrl,
            variant: widget.cacheVariant,
          );
  }

  @override
  Widget build(BuildContext context) {
    final trimmedUrl = widget.imageUrl.trim();
    if (trimmedUrl.isEmpty) {
      return widget.errorWidget ?? const SizedBox.shrink();
    }

    final currentFuture = fileFuture;
    if (currentFuture == null) {
      return _networkFallback(trimmedUrl);
    }

    return FutureBuilder<File?>(
      future: currentFuture,
      builder: (context, snapshot) {
        final file = snapshot.data;
        if (file != null) {
          return Image.file(
            file,
            width: widget.width,
            height: widget.height,
            fit: widget.fit,
            alignment: widget.alignment,
            filterQuality: widget.filterQuality,
            gaplessPlayback: widget.gaplessPlayback,
            semanticLabel: widget.semanticLabel,
            errorBuilder: (_, _, _) =>
                widget.errorWidget ?? const _ImageErrorFill(),
          );
        }

        if (snapshot.connectionState != ConnectionState.done) {
          return widget.loadingWidget ?? const _ImageLoadingFill();
        }

        return _networkFallback(trimmedUrl);
      },
    );
  }

  Widget _networkFallback(String url) {
    return Image.network(
      url,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      alignment: widget.alignment,
      filterQuality: widget.filterQuality,
      gaplessPlayback: widget.gaplessPlayback,
      semanticLabel: widget.semanticLabel,
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        return widget.loadingWidget ?? const _ImageLoadingFill();
      },
      errorBuilder: (_, _, _) => widget.errorWidget ?? const _ImageErrorFill(),
    );
  }
}

void prefetchPostPhotoCache(
  Map<String, dynamic> post, {
  bool includeOriginal = false,
}) {
  final thumbUrl = (post['thumbUrl'] ?? post['imageUrl'] ?? '').toString();
  if (thumbUrl.trim().isNotEmpty) {
    unawaited(
      LocalPhotoCache.instance.prefetch(thumbUrl, variant: 'thumbnail'),
    );
  }

  final authorPhotoUrl = post['authorPhotoUrl'];
  if (authorPhotoUrl is String && authorPhotoUrl.trim().isNotEmpty) {
    unawaited(
      LocalPhotoCache.instance.prefetch(authorPhotoUrl, variant: 'avatar'),
    );
  }

  if (!includeOriginal) return;

  final imageUrl = (post['imageUrl'] ?? thumbUrl).toString();
  if (imageUrl.trim().isNotEmpty) {
    unawaited(LocalPhotoCache.instance.prefetch(imageUrl, variant: 'original'));
  }
}

const Color ssOrange = Color(0xFFF4A261);
const Color ssOrangeChip = Color(0xE6F4A261);
const Color ssOrangeDark = Color(0xFFE8884A);
const Color ssOrangeLight = Color(0xFFFEF3E8);
const Color ssOrangeMid = Color(0xFFFAD9B8);
const Color ssBg = Color(0xFFFFFDF9);
const Color ssSurface = Color(0xFFFFFFFF);
const Color ssTitle = Color(0xFF545A60);
const Color ssAppBg = Color(0xFFF0EBE3);
const Color ssText = ssTitle;
const Color ssText2 = Color(0xFF6B6B70);
const Color ssText3 = Color(0xFFAEAEB2);
const Color ssBorder = Color(0xFFF0EBE3);
const Color ssSeparator = Color(0xFFF5F0EB);
const double ssHeaderActionSize = 48;
const double ssHeaderActionTop = 2;
const double ssHeaderBackIconSize = 24;
const double ssHeaderBackStrokeFactor = 0.162;
const double ssHeaderMoreIconSize = 19.2;
const double ssHeaderMoreIconGapFactor = 0.16;
const double ssHeaderTopPadding = 12;
const TextStyle ssGroupHeaderSubtitleStyle = TextStyle(
  color: ssText2,
  fontSize: 17,
  fontWeight: FontWeight.w800,
  height: 1.15,
);

class SundayHeaderBackIcon extends StatelessWidget {
  final double size;
  final Color color;

  const SundayHeaderBackIcon({
    super.key,
    this.size = ssHeaderBackIconSize,
    this.color = ssOrange,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _SundayHeaderBackIconPainter(color)),
    );
  }
}

class _SundayHeaderBackIconPainter extends CustomPainter {
  final Color color;

  const _SundayHeaderBackIconPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.shortestSide * ssHeaderBackStrokeFactor;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path()
      ..moveTo(size.width * 0.68, size.height * 0.18)
      ..lineTo(size.width * 0.39, size.height * 0.44)
      ..quadraticBezierTo(
        size.width * 0.27,
        size.height * 0.50,
        size.width * 0.39,
        size.height * 0.56,
      )
      ..lineTo(size.width * 0.68, size.height * 0.82);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _SundayHeaderBackIconPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class SundayHeaderMoreIcon extends StatelessWidget {
  final double size;
  final Color color;

  const SundayHeaderMoreIcon({
    super.key,
    this.size = ssHeaderMoreIconSize,
    this.color = ssOrange,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _SundayHeaderMoreIconPainter(color)),
    );
  }
}

class _SundayHeaderMoreIconPainter extends CustomPainter {
  final Color color;

  const _SundayHeaderMoreIconPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final dotSize = size.shortestSide * 0.28;
    final gap = size.shortestSide * ssHeaderMoreIconGapFactor;
    final totalHeight = dotSize * 3 + gap * 2;
    final left = (size.width - dotSize) / 2;
    var top = (size.height - totalHeight) / 2;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    for (var index = 0; index < 3; index += 1) {
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top, dotSize, dotSize),
        Radius.circular(dotSize * 0.32),
      );
      canvas.drawRRect(rect, paint);
      top += dotSize + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _SundayHeaderMoreIconPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

const String kSundaySelfieLogoMarkBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAQsAAAEYCAYAAABLF9NnAABf6UlEQVR4nO29d5wdV3n//3nOOTNz264k27KNbVwBY5kaTC/GdEJo'
    'IXcBW9oiCzsQShKSX0K+gXtvwpd8QwLEITFY2Nom2bCXBEw1IcT0FoopknHBvWBbtqXdW2fOOc/vj5m5u+oraXfv3N15v6ziq1vO'
    '3pn5zNPO8xBSFhQGKPwLA+Uydf7h3B20v+dXARS3r+M9HixXOHoXEMD7violZenZ7wmccmgYIDADKBOqkRBsX8dUqdgF/RxmQnVA'
    'AHOEJRKTVEhSlpJULOYJMwgohcJwCFG4vnS+Ou+sc46xXF8NeFCw/Rp8IglkpAGshGDASpBvLO8mNjstcQDhkGODZraV3UmXbm4c'
    'ck2lksC5O6gjIpUKpwKSslikYnEAmEEolwjn7iAUq5Zoz4uQrz9fNe4/63jTpjOEMGcz+AyQOIkYpzNxlhgnAHQcExNAjiDKKDHr'
    'W4ABYxmWWQPcYoDBIBDVAL6fgBnLMATcDcLdxLzbMP9aSvGA9enuvr7aIzRQNfuuuyRiQUvFI2UhScViDswgVItif5bD9FUja6Gw'
    'jsDPALCOQE9k4tPBeEzWVUIqEV6WzGAA2lgYy/H7wjLH/9SBCEQEEFHnQBARHEmzj1Hob8ACzUDDGm4y4QEC38WMWwC6EcLeIEne'
    'mr3lt/dS5Vt67mdMTRVlEcD+BC8l5XBY8WJxIIHgKzf2zTj8VBCeJxjPZfBTQTit4DkCRLCWoY2FNhYWbMHEQGw0cHilM81+vxT/'
    't9fnhxbFno8QmKL349mXAwQhiEhJghICJAhgRq2tmRgPgXCLtfwzJekHWtuf951++q10QaUjHrHbkgpHypGwIsWCAUKpRNVzd9DA'
    'HFN+ZmL98QLq2Qx6OZgvYNA5hYySIEKgDQJtYZktQAxiityG/YrAoq2dwSCOTBZigImIhJICrgwFRBuLlq93A7RdCHyHLV+vlf/j'
    '1Rdd/WjnfUolAQCpq5IyX1aUWMRWxFxf//6J9fk+67yIBN7IwMuloNMzroIxFm1twBYmNBk4chiS953NWifMADERkxRCeEqCBKHZ'
    '1jBsbwbouwz7FQTi2/0Xjz7Uef1UUaI4ZYkoFY2UA5K4E38xiM3vuSJRnxx+prX0BiL+AyJ6Ss5zEGiDtrYMhk2yOMyHjgXCxESQ'
    'niOhpIAfGPja3EbAlyyo2pet/SD+XphLAmVgodO/KcuDnrwQ5ktsascn/66pi49RbX4Ds30zGOcXsq5njEUrMGCGATERSHR31YsD'
    'z8ZVhOcIchyJetMPAPyICFsZwRcKG7bdD+z7vaWkAMtULPY+2XdPbjxbsN1AQDHjqidIIjR8A2vZ9LoFcSTEwiEEZNZRYAANX99F'
    '4CqgJwuDW38BpKKRsifL6gLZ++Se2Tr8ZGK6BMwX5jPuMdpYtAJtiYkZEHMyliuSMNYRlpu5SgpXSdRb/gwzfYYEf6KwYexnQPi9'
    'lgFUUtHoCrxHXgxAGFdfcpbFxcLMVK0OiDizMTM2eC6RejvAG/JZp7/lG2hjl7WbcfSwZSaWgmTWU6g3gxozJgBzed/wxHYgDoSm'
    'adfFhhlAtRj+T7G6X2FgACiVgHN3AMV1ACqLLiA9LRYMEKZmsxu7xzc8QZJ8O0DD+YyzuulrGMMGqRUxb6LCMdsRjVawC8AWwfqy'
    '3NDkXUAoGvurHk05OrhUAgBQpbLn41N/hlqrCaIZQCsEANaMjO/7+qkisH3dPq9fKHr2AmIuCaLQLK5dcdFjOOu8W4A25TLOcS1f'
    'Q6cicVTEoqEkyYyrUG8FdwuBy7Ju9goauLwWl8On8Yyjh0sloDxrGewe3wAJCQtCVHc3e6UyQMSwCIt7BROMJfQJHzS4dc77lcNI'
    '3ALScxfS3JOUp4puw+/byIb/v3zWOaPtGwTGpiKxgMSi4SohXSXRbAc/tsyVwtDYV4DUyjgaYlcitgTqEyOzFbtEyHkKAGBtuHUg'
    'KsWDEAQlZ73pWjMIdwUwYHyN/rdNAgCmpooYGKgu2Hp76oKae2I2xkdeYAl/l3XVBcZatANrABa00HKaAiDOoAA5zxHtQFsGj7cb'
    'pnzMpZN3MXO0jSUt6povPEckHh0dgisJIEJY72Pha9MRB1DY3mT2/wGEXzkIoYXhORJSCjRaPgCg4Qus3bQltDIqlQW50Hviwppr'
    'Tewe33CsIPlXAvTOrKuydT+wAJAGLpcGZrZEJPIZB412cIdl+76+wfFPA6mVMV+4WARVq+DL3oX6mhkIIZB1FRrtANYiEof5X5oc'
    '/84EJQmZ6L2MAfqHR8N/ZRx1ADTxYjE1VZRxlmN6fPj1Soi/y3rqKc22hrFsiCC7vcaVRlRebj1HSGsZxvKnjGz9Tf9F1+zkYlGi'
    'WrXpfpP9w1wCUQW7rhqB4wBZT6EdGOhwU8FRX9Cx9ZFxJQIdui+FbA00UD1qwUisWDBA1amiGBiomt3jG451hCpbxp9kXEnNtknj'
    'EgmAwRYgKmQUNdr6BmvMn/cNT1wf7psF0hTrnsSux67xDXCFQtZzUGsGAI5eJPb5rHCXI0IL0EfOqx+1YCTyYmPmeDcnT4+PvEAJ'
    'fCzrOefVW0HHDO72GlNCYisj60kZaNs0zH+XXz/6j0RgLpVEmi0JiYWivXUYhgkZR6HW1hCLeAXGwpDPOKg3feRbLnDJFcAR3mUT'
    'd9FNFYuSiJgAro0N/4WS+JrnyPNqzcBE+7ETt+aVTFQrLxttbZmRzTjyHxqTI+M7L7uonyoVOzVVXPFuIjODKhXUJi+BtksjFEAo'
    'FAyg3gyQz7qYzrTDdGpUz3HY77ewyzs64gDZI1cUVznZwmVZRw752kJba0UqEokn3ulayLii0Qq+GVizafXwxG9XcuCzU2n54m9i'
    '5q4z0Jd1O6nOJVsDh+lWRxL8wKAwNLZHNma+JOYCjE+omYmNT8rmCl8ueGqoFRhrLHMqFL0Bhc6jqDUDk8s4L3aE/HJtdOhpNFA1'
    'vFItjOiirN19JvKuQn2JhQIILQzLNgp+EnZdNQKqVDoVo/Ol6xchA8SlkqCBqqmND/++FPzVjKueX2vpNIjZoxBB1pqBcR15tlDi'
    'uumxkTeuRMGIaxx2TayHAKAtx90XlxwCwdcG+awDqY7skuqqWHA0SocqFTs9NnyplOI/lBCn1Fo6TYn2OESQLd8YJcUJjqJrdo2N'
    'vHUlCgYBUHCQyzjwtT2s+omFXwyh0dYQxNg1NnTY1kXXxIJLJUEEBjNmxkf+3lHikwxk2trYVCiWB0SQrcBYAjxPiS27xgZXjGCU'
    'IvejMb4BYEY7MGE9dhchANYychkHShz+pd8VmYtTalw6X9XPPONf8xnn7fW2ZmZGWq69/GCwVVIKgFvtQG9cPTxxzXIPevJUETRQ'
    'RW1sGLmsg1orgEjEqc1wlYzES6NvcCui6+6Qr1xyyyIWip2TF/XXzjpzSyQUJswJJ+LbTFlgCCS0MRaMTMZxtsxMDL1lOVsYDIQF'
    'UFPFsDKNk5R2JLQDA8+RgHXCh6oD83rlkopFLBT3XVVc67FbLWScDbW2NmnXquUPgYS21oI5o4TcMj069IZlKxhRHKDW6gOD0dYG'
    'SZILgOA4crbOY/u6eb1qycQiFoqZifXH9zuFqULGeUWtGRgC5Erqf7mSIZAIjLVCUFYpcVV9cug5y1Iwzt0R/kkarpIwhrvSBu+A'
    'EMMYC6bIXapUZne0HoQlEYtYKB654pJVBLUtn3FeXGsGacZjBUJEoh0Y6yh5DCAmmxMXP44GqqYz9GgZQVbCdRJ4ijNgoo1rDRwD'
    'ACiXD50VWfQDFAvFXVPFrJPxr8p7zstSoVjZCCLR8o3Juepxhuz49La3HkeVio1T6T1PZNZbJCpYMQfqNNPhZgMAUJ7XqxaR8OAz'
    'UB0QtWbhk4Wss6neDAxSoUgBwAxTyDpyutn+bH/LuxD3PcagXOFe360ad8GrTYwgn3GWvLz7UDAAQYC14d/7h0Y7W+cPxqJZFqGm'
    'loiIeKaR/+dCVm2qt1aeUETD0y0zzP5/sQ3//QDPCV/LWIb9IYgg663A9HnuH814/l9SpWJRLfa8OzLbLpNnKw8TRhyjUFHHrWp1'
    'xyFfoxZtNVNFQVQxM+NDf5r11J/Ww12JyUg1LxJzRwZGDwkliaQQ5Egx20hgTvPVuMll1JcuHsPeIZ7UHpqNc4cyEy2HDBIzREtr'
    '6yjxgdrE0M9oYPy6ZbO1vQfkXR/GcxdFLOKCm+mxkTcqSf/P19ayxbI4uefCiG4dHF7AUgjhKkkyaqbaCjSMsbuNpUdbgb2NCC1m'
    '3CYIdwOAYBgmBNayBSCJ2AUJYrarCHQmwMcy6FQAJwpBq3KeI4gI1jJ8bRCmIsPP7tW2gkQgY5gzjvC0FZ94ZHzD+TRUuauXBWOP'
    'IqfIp0rUic+AkAQ7J0tTnEf6dMHFImrRb+rjG88jgSsEkdfWhsUyKriKx/8RQWYcRVIKGGvRbJtmOzC3cKC3g2k7Ef9SsbkpIN7V'
    'P7T1wSP5rF3b3r6G2s3jiMRZdd9/PFg8BcxPIeDsjKtWKSnCgc6BZQAWPVizQkSiFVhTyKjTZ1r8/7hUWg9EXe974v68F3OLnJJ4'
    'JIghhYAxFmQjPS6XgUNsWV9QsQj3e1RsbXToRAiecJVc2/D1MulFEU7sIoLMOkpIKVBr+rbh6xsJ9AMS/F2y/ItcvXErvbNa2+87'
    'RI2Hce6Og55CVQDF4pQFEeiiTzwK4FEAtwC4DgB4qujO1HNntgL7DATm5QSc7znidEdJ2ZmZ0mPWBhFEo61NxpFvrZ95x1cLQ+OT'
    'zCUBqvSeWEQwGNZwtCckWaqhpAh3ofpe9Mih17dgYhEnifgr7/JqO2v/nnfVObWWNoKopwOaYZ/J2VmgzbZGyze/BumvKctfyuQb'
    'P6GBPcWBSyXREYTt6xjlMlPY7IGB+Z784cv3EZjt65gGKj6A30S/ts186uIT2mRf4mv7R8z88kLW7Qu0QVubXup8Tjbubw/xocb4'
    'hm8RVe4qlUqi52asFkOTnonQ9MM9ITZJWVSmyPwk0KWbw0Y4h8iEAAsoFmFz3YrZNTr0F6vy3h/We7yWIp6TkXGUkILQ8PXdvrZf'
    'J+b/aAbiO2s3jc50nhuLw/Z1HKb+9jq5j2Kc3P4EhgFCKRKQ7euY3lZ5AMA1AK6ZGRs8t9YMLgT4rTlXncEAmoHuCdEgkGgFxvZl'
    '3FNqLa4wYyPKwOIM41tMwhWzzIJ1E56SaGmNpMgFg6GNQXQvma04PQQLsvpOKffk0EsViS8wkDGGqRc3hsWWRMZRQglCva1vYeZP'
    'kgiuKWzYdn/neRxXHHa/LoCZCdUBMXdo8f0T64/Ps/ojAi7Jes5TmRmtQNukZ1EYYEFgSYLbxrxu1dDYV+aOquwV4rZ1M+PDKHSh'
    'ld4B1wWGKyV8Y0HGojAyPu+O30e9/Cjwy7XJSx5D0P/jKvHElq97rgN3PKYv40gJAnxtfwHYUePR1f0Dow8BoShWz91BxQRPEo/X'
    'GM9aeejK1/XlvLUXsjXvznnOurY20CbZ81aY2WZdRzR9/b+tgF563MVX1eJu791e23zpbFEfH4aQAtYmY+nMQCHroN4KUBgcPaxe'
    'nEclFh1zGMDMmXeO92Xd9b1Yys0MoyTJjCPRaOvfGMv/4svgmuM2bJsGwlQwilO2l8bzxdZG3DNi17YL1yjrvZMY7815alWtHViE'
    '7UMScL/bF2a2uYwj6n7wJ/0bxi6fO2yqF+icKFNF1Jt55DwHjbbuqifCDEhBYbGYscgPj8+rcjPm6MQiMg9nxocv9By5zdfWIgF9'
    'PecLc9hpoJB1qN4Kppnxr6ycy/ov2rwTiEUiuVbEfGAGoVrsiEZtfOPTheCSI8XrDTMCbRNpBTLYeo6itm9uZeU8r+/CzQ8DvTW4'
    'KLYu6pMbIQXNxgi6tR4GCjkHtYaPviPo8H3EJ0mpVBJAhXeODZ5MRH8HROWtPQIzjKMkeY6gejv4IjG9tG9o9P39F23eyVNFyQyi'
    'garppZNzfxCBaaBqmEHMJVEY2vLz7PrRN/q+fYexvDPnOYIZibtjE0i0fc35jHo8mWBDeBxKibSCDkQ4AYyRaygE2iCfcWDnsxd8'
    'UWC4SqDRDOAcYVrjiMWiXA5PRAeilM84Z4W9FpN3h9qbqMLa5D0lrbUPtrR9xz/deuob8kNbfrKcRGJviMBEFculkhAEzg+PfsLX'
    '9uUtX/+gkFFyzh6U5ECAscxgvnTXtgvXABVO6FaLA1Mugy7dDMdVaLQCeI5c8psqI5oEJQiGLTIXHdnckCP64mP3Y3p85Hwl6L8A'
    'VjY8iIk+kJaZCUAh61K9FXyTrXln3/DEdmA2o9PlJS4JDBCmQtdk1+UXrnHy3keznhpu+JqjDTyJOY7MbHOeI1qBeXd+w5aP92Rm'
    'JIoLTI+NwHXC7eHWzq/v5UKRz7mYrvvoH9zSqdY83E8/7NXGyn7f5kuy/ZngulxGvbDeChJfpcnMVkkhpCD42nw8n8n9DQ1cXuOp'
    'osTAypz6He/hYWZqTGwsCUnvByACYxNTns9gm3GUaPt6h1b+C1ZddPWuXhy6zMUiqFrF9MQw+jwX9bYPG/WTXLTPjH6L4xSFbA4Y'
    'uLyTwjxcDv8CL5eICNyXDYZynnpho518obDM1nOkYOaZlm/+uDA49m4auLzGHA43WolCAQCdDlVEyA+Nln3Nm8BoukqS5a4513tA'
    'INHytc14ap0K3DcRwL24jZ2qVXCphL4Np2Gm7cNzFJQU82pndySEnYQ4TJM2A7QCAToKoQAO07IolUqiXK7wzJaR40jhB54jz2xr'
    'zUmOVTDDZF0pA2MfbAdmaPVIuAV6OTRZWSjmuiUzo0NvcVx5FTNySbEwmGFynhKNdvCdQst9GS7drHtR4OfuEJkZH4EUBM8RaLQN'
    'gIVxS2LxcaSAFISWNng0U8OpA9UjilPM5bAu8jJC80+49LZ8Rp3VCpIvFDlPSV/b3/q+fePqkfHreKooUUmFYi6EKGMyVZR9I+Of'
    'bvnmEgBBdOfr/vdEEC1fQwh6bjOvn0sAz1bQ9g5xqxJmoG9oFAZAOzAoZB04SoZt7o7w6+awyxKECIuuDDN8X6NvcDQUCsZRCQVw'
    'GGLBpZJApcI8NXQiM1+qjeXu33MOTJzxaAfmVxr8ulUbx74f++i9eFdaCmLBWD0yvi3Q/E4CWSGic7ib6wLIMmzOcxxr7FsAzK9p'
    'ZAIhRPvuuYS+DVvgizYazQBGWxSyDjxHhV84RwIAnvP/c36BOwLBDLiORCHrgBmotX0YMPLDYx1xWohrdd5vMVuANVIuZJ3STNNP'
    'bKwiFoqmr38ZBHjj6otHb1vuE7AWij1ckrHhv8tnnPc3fG2A7lblMth6Sop2oG+zsM9aNTT5cLzVoJvrOhrmugXNsUFoEX7FrhRw'
    'HQlmhrGMwNg95JoorMRUQoDCgD18bSGIASORH74qfP/DqM6cD/Mqz4j7VNQnN51irX6bH5jEWhWW2WZdJZuBvlkTDay+eEsqFIcB'
    'AcwDVculkkD7/r+vkf/kQtZ9Q7fL+Akk2oFlR6kz/cC+CMDnwkBn7x7XzryOcgk0HF7Uu8c3oG0EAh12UGQg6qI453XMMJbgh/YF'
    'YA1a2sfaTZ8GgNn3XEChAOa7Rb0MoAIw6+FCxjlpJqGp0jDNJkWgzYMw9sJVw+M3pUJx+BDAJYAql24OapMXvaPRorNynnxyvd31'
    'RkbWc6QMtHkVgM9h+7qetSpiwptuNM28jD0ucAaw+1MXQzoBwICrBHxtYU2o2X13PXaPOEQ8ET18j4Xf2H9I+yA29aa3XXIcaf/H'
    'nqNOT2IGhJlZSQGAa0bjzYXh0a+mQnF0xK7n7vGNz3UlvgJglTa2azNpGWxzrhKNtvlZwdrn08h4q2db7x0AZgDVIrB93bwCklwq'
    'hf0oilOLXuR1aMsiNvV0+41Zzzmj6etElnUTgQWRaAf2L/uHx1KhWACIKjb8Hrf8YNfY8PsLnvq4ttaiW5W6TORrC4DPmlbyNAA3'
    'oVQiVHq39d7ehNd7FcBsURX2Ny2sXAkjvx1BWfxDclCxYIAwULX3XnFJDuxfktAwRTSsxpXTzeDKVcNjV8RVmd1e17Igil/8tH3/'
    'FU8g/zWFjPuqWqtLwe1wrwikFKusb58A4KbqIfqZ9jLU+W0/FkYX2ocd/IBPFQUB3Jdtv8JV4hmNdiLdD5vzlKw1gxtIOe9jgMrb'
    '1/FyMk27CQGMMnDepZsDqdTfNv2groSgbtRfEEAIi+ygJB4LAMWlXsQK5uAXfrFqmUEC4kLPVQRQou7WzGAlBfnGPCoIf9x/0ead'
    'KJWo5xq8Jpx4t2r+oit/ysyfzHqKeNEKlVOSygHFIkyXgluTF58FxstavgbAibIqQMyuEqQN/31+cPRHPFWUK2XnaDdggMgXH621'
    'gjsyjiQO55SkrBAOfPFHviAL+/pcRq0JjLVJasHGzDbvOaLp628VjP0El0oCxTROsVhQpWJRKlF+05b7BOEyKQV1zbhgYM6IyJQl'
    'Yr9iwQgbwPBPLnGs5dclbUQKAyyFoJZvaob4r2lkvAX03rblXqOM8NyoafvpRkvf7TlSIOqGvhQwwCDIhm+MkHQzAKDY+7UWvcL+'
    'LQsO25c1bmw/g0DPabU1lrRTxyFgZs66kgJrL1+1YfyHqfuxNFQi6+KEkfHfCYGtjhRY0qbVDChBsNbuht+6HUDP7hHpRQ4ag7CW'
    '3pjLOK5lGEqIcRE1Q6FaK7hDWv4YMwjFqVQolhhmfKbeDhpKCLFUmRECrKMkA/SbjC7cDQDLqcYi6ewjFgxQVIyTBeHlxoYOYhfW'
    'tn/CduYE8EcLI+O/A0rUSy36ex2qVCwzKJ+p/ZqB72ZdyViiQKcFkwgDZ9fRpZuDqamiTFPkS8e+lkU0B6TZ7Hsagc5tB8lxQRhs'
    's64SjXbwi7bQ42GLv/TOsuREowWIeau2TKDFv5kwgx0pqN4KHlWQnwGA4jLYG9JL7CsWURbEgl+ezziutclxQQBElTn41+M2bJtG'
    'tSjSoGYXKFYtA1SfaXyuFeif5FwlLC9uoJMBm/EUATyZGbry5tIKarCcFPYQiygLYrl0viLCBcyciPmMQGRVOEo02uZXfsv9DwYo'
    'TZV2ByIwuEQnvLNaI0sf8LXVUSZ1UYTbMtusI2W9Gdwl4H6EASovxgelHJQ9LYvQBeH2mY8/0zI/vR0YcFImjDEgBIEIVx5z6ebd'
    'mEqtim4SV3UWhke/qg3/U85zBNHCJ0cYbJUUFBjrg/EnuaHNd6FUotSqWHr23EgWuSCBMM/KKLWqFSRjhymDraukqLWCe2QgPssA'
    'YXs1FYpuU64woyRwKj5Qu/OuEwo5Z2O9FZhw9MgCDN0GW0mCBBH5xvxZ/9DYl1bSfJeksacQRAEjYjxXSZGcKjkmdh0JQfSF/KYt'
    '94V3lrTUuNsQgVGuMF1Q0Xfmam+vNf3RfMaRYY/JIx+JGLWfNK6SQghwW+u/6B8auzwSimSckyuQjlgwQFSp2Psn1ueZ+fnGWCxF'
    'lHs+EEE02tpIsv/JAGEZb0vuNYjAzExPGqj6hdtOu6TeCD4qCJzzlIz6zZr5xjKYmZlhBECFnCONtfcExr5l1dD4R+KG0UhTpV1j'
    '1rKIUqYZUmcDeIKvLZCATptRqzxiyzumd+d/RACngc1kQURhLLxS0YXh0fcGll/bCvT3PUdQLqOkFETRLFXDDBP+nRlgi/gxZnaU'
    'pELWkQD8RiuYDIhf0jc4Vo1dj7SmorvMxiyiu7XD9NSMJ7NNX1tKQp9NJpZSgGG+dsI7L6/FzYO7vayUPaFwWxmFJurYV26+7FXf'
    'eMzqE9/kB/ZiJjwv7zmZuFwn0CZuT0+OFAARAm3R1ub+wNqvSWGvzK0f/x4Qj1ispB3PEsCsWMQFLszPkCKKV3TZrmAAJCAa7SCA'
    'sF8GgOXcGanXoXCjV9y7sw3gama+pjE+/Hu1pn6WFDjPMk4iwuMBLjCo6Qf2NgbfBOJvC3K+m99w5T1A2PsV5RKlQpEcwm3o8dyT'
    '60uqdted38hnnBfVW0HXLYvOUNxA35in4Dm0Ydt0r8+KWCkwg+JKz33+bXzDsXWRda0f6L6LR3fOdS+4FE4aSzMeySO0LOI96A/d'
    '00+EU4zhZNRsMrGSAi2ffkSD26aZOd0H0iOEgl4Nz6RSKQxKb1/HqFSYhiYfnvtcLpUEzt0RtkNMRSKxhGJRLhFQ4UZAZzDoJN8Y'
    'LMzAs6OEmKxlMPMPAQDVAQEceUouZekhgPfeGRru6YnuUJRaEb1C6GbEcQBrT3akyFgL7vZ+EAZYEolGO2hL2J8DwHIYKpMSWh1E'
    'xBQO2kqPaY+w594Qa852HQkkorcis6MkCLgjcPQtAIByWpCTktItQrGIW5MRPTYBzkcIEytJAIm7V1909aNAIhyjlJQVi4ib3QAA'
    'gZ4A2/WM6RwI1vKNQJiOQ2qypqR0jdly76miZHB/WE+bjDJvACCBsNdiNa2vSEnpJiJu5z7dzKwG6NjEpE0Jou1rCOY7u72UlJQU'
    'QKBcJgBwmVaDsdbY7u8J4XCaEQXWWm3wOwBpy/eUlC7TcUNaxP2WOLukrd0PRNzoBpghh3YBSFu+p6R0GdHZQCbViQLkWU6CGxJ2'
    'T2FQTUJOA6lWpKR0m9k6C4u1GVcRg223C7JAoSNEDN9yyweAclpjkZLSVcQef0nQYGwKS4GtZUrLu1NSEkBHLCyTEqLr/keHaL88'
    'kcomZ1EpKSuYOWJhw78nxrjg0NCpdXsdKSkpwFw3hGA7W9W7DCH2iMiRUrvho4lRsZSUFUmnU5a1LMOrFF0XDGYiDteR08LmASCq'
    'B0kVY5kSt+RDuUQoY9+K3agXxsHeAOXSHs2cq5gz4rBc4WhHfHoOHSEdsVBK+ZwAoQAAEBAWh/EqpegYAGHutNLVVaUsAHG7vOq5'
    'O6gYP1is2jBTDgAVPqLjHL/2QETvGTfaARAKULnCaee1+TFnyJBtaouwerPLgkEA2XCLuvID+1gAP0r3hvQkxMyoVgdEEQC2r+Nw'
    '0+K+FzVPFd2ZmcIqoegUQTYLolOMxWOJIAF2mXE6CCeJ/Qy9sgAI2AXLD0LgfoAMW24T4Tck8Ig1st2WrTuO9fz6Pj09K7MtABGt'
    'EZVK2mdjP8y6IQYzli0TgRjdb34DJus5UgbantbVdaQcFsxMsTjQQNVEHb07FyiPDmV2AScqIR5HhNNgsQ6CT6m16HFC8WomnGQA'
    '1xVCZD0JHInzSQAso+FrWAsDsi3POvfUms7OmfHh34BxLwv+pSC6vYXgVqJt08CevUKZSwLVHYTilE1bOYaoeM+FYfuoYBEIQS4n'
    'qd6C+BQAaZesBNMx7YvV+MLqXHg7xwZP9lg9EYKfDPDTa0TnOuBTAazNuBJSinBEumUYa6FNmAXztWVf26NowsREREIISALlHSXP'
    'FkRnC0nPBwNaG7S1aWTg3FkbH94BQb8gy78U7P46c9pNdxJVdPg+NGt5rPAeoSquoyahdhPZNhHc2K7rOgww44lAp09jGuRMCMxM'
    'qA6IUCBmL6Da6NCJkOpplu2zCHguwE+B4McUMg4BgLUWgWFoY9H0te2MyIyn30VucOQMyyNfIcVjEMNZioGOS3ei84eFFCLnKHGO'
    'kuIcAG9qBwba+I/U7z7zxumxM77PhG+qQNxAtOW+2PLoCMcKtDg6bohkNW3Jn5ZEfSYJakFM2lqA6HSeumQVDWzeHQ2mSekSzKBq'
    'tSi2b1/HRGQRWRDNscGzAhKvFISXMdN5kvix+YwDMMPXFoGxqDcDEw3SpY4ggMTsaUZ7/LEQdFxpAjpnzpzPM5bZBJrhdy564Uhx'
    'jKvk80nQ81u+/ktN9t7a+Mh3BPg6UvQdotHbQuGg0KIqA6CVEeOgeA7H/RPr8wU438268mlNv/vT05nBUhAZa5tk+XmFkfEb0gna'
    '3YFLJVE9dwcNzJkBUp+69GRu+S8F8AdgviCXcY4jIvjaINB2zmBkFoi1oQdgBoOYoyFbwlWCXCVhjEXL1ztB9G0A15J1v5EfvuLe'
    'zuuminK5WxsqPoSPGdxanxkfrgsiUAKmkRGBDFub85xsvR08D8AN6UDkJYWYS1Quz7bqf+SK4iovm38RAwPc8i/wHHmykgLtwKDe'
    'DiyYmIgJIBFmMYAe0YgOezhBAPzAsB9YC2JylDzOU/IPDds/bLbb99QmRr5kGZ/uu+3U79FARYfxjdDaWI43tT0mktXGRz6bz6g3'
    '1VrazB7s7sEMU8g6st4K/rNvcPRNNh0ytCRE4wc7J/vMxPonAeotRPhDQeKcrKvgBwa+MXHMQXQ/4b74RNPgLYjJlVK4jkStGRgi'
    'fI8sPl1j+7kTRsZ/ByzPyWqhWEwVJQ1Uzcz4yIcKOed9tUaQELFgdh1J7cDc1w7EM9du2nJfOpVs8Qh98Nkipcb4yPmacLFgvD6f'
    'dfq1sWgHJnIxWBCt5AgSW2ZiQZAZNwz9Ndr6DgDXWMOjqzaO3QIsL9FQc/9HCHrAWkYSyiwAgIgoCCw7UpwkYZ8J4AvpVLKFh0sl'
    'UUZ0QleAXeMjL3OI32MYr+7LOLLla9SagQExUcfF6P750V1IEAEW4EY7YBDgOfJ0R8n3NVr+pumJ4U/D8OU0UvkNAEwVi7I4FVWq'
    '9igKCGvoAYCBG/3AgIhEIgqzwjXZjKtks+2fD+DatN5i4WBmQrlM8V1venL4hcLSe0B4fc5zVKMdiUToZqQCsR/CpE5oYbW1se3A'
    'sqPk2pwj39VoBRfWxoe3GSEuX7Vhy02gWSu+2+s+EhQwu9nGWrqbYaeVpH6dmC7fTMZYaItX8Oc39tEbKjPpJPWjgwHCVFEQkQHA'
    'tYmRpzLjT8F4az7rePVWgFpLGxBEEtzRXiFOBQfacKCtVZKOzbjOuxut4MLpieHLdNP9OA1s3g2E1lyvuSZhejRqWddn9e0CuNVR'
    'IkyqJgACiZZv2JFiXWMaLwWATh1/ymHDpZIggGmgamqjQyfWJzb+swB9u5BVw4LIq4X1EEwEmQTLshchIiKC1Ia51gyMlHRcwXP+'
    '3snob82MD78ZCF0+5pLgrucd508YfCEwMxONjLcsYXtYgpucIGLkipAFb2AGoVjtKUVOAgwQTxVleJKCauMbN5AS38l58r0k0F9r'
    'amMtpyKxgFDooMhAM9dbgc264qmOkp+emRi5tjYx8lSiiiUCx0HQpDO7yDBwCDDdwJ0gZ0IgiGZbg4BX1CdHngLqjDNMmQdzrYmZ'
    'LcNPbm4d+ZyjaMKV8nG1ljbaRCKxAtKf3SAUDRLNQNtAWy546nUEXF+bGH7f7aNDGapUbDgRMNnf/+wFFw/xseZnzbYxUX4yEdYF'
    'AaSttfmMU7CMTQRwOhtgfsTWxPWl81V9YuTdwqHrs556va8tt7S2qUgsHVEmiWotbYQQa3Ke86G1Uny1Pr7xPBqomvAemNybYOck'
    'iesXZibWHw+o//WUPLUdGE5KLp2Z2ZEShs1OHeD5qzaO3dKLQaKlghlULpeoUqnYnVeNrMu5+H+ukq8NjIU2nIg6mpUMMzOIbN5T'
    'suXrR43F3xVuO/VfqVKxXCxKqiYvY9JRMSJiZlDf4NYHwbjBURIAJeZCJCLyjeGc564lSe/u9nqSTFiBCa5UKrY2PjyUc/A/Wdd5'
    'bTPQVhvLqVB0nzAGCllvaUNEa7Ke/FjzrDs/88iVG0+jatXwVDFxx2hPkyfKMljQty1zoqapA2FCu+VrloTBma3DT6ZKxSbZbOsG'
    'PFWURBW7e3zDsfXJkc1SyTEpxQm1VmBCMzgZlmJKSJg1sdz0tc1m3D/KePj6oxPDL6GBquFSsrIle15oUdxCWfu9RjsIpAiLs7qy'
    'sv1ABNKGbS7j9LPm93Z7PUmCGcRcElFK9GmOUF/Jec7btLHc1ia1JhJMaGWQqDUD4yrx+Iygz9cmRi6mSpgtKSXkhriHasXFTnzl'
    'xr66yz/wHHluK+j+dvW5MMBSgAHyteGX9w+NfnfvjU8rjVKpJCpR7GZmfPjNUtBlniNPaLSNQZgKTekRLLN1pBAAoA3/w00tp3Te'
    'pZuDJMTn9jmP4kXVJkY+ks84fx7tqkvUXYmZbc5zRKOtv1NY47wKP31Ma6V2aY6F8telonvaWfkPSEHvkyREWxsrKDkinzJ/LDML'
    'IuQ9RfW2/oyW7bevvujqR7t9U9z3ZIp6Rlhhrm20A020n+d0GSISDT+w+Yx64e5H/PdQpWKrK7CqM45P7Np24ZozH1fYWvCc/2Mt'
    'yDepUPQygsK5ObV2YPMZ582O9b68e3Lj2URhPUbX1rXPIwNhdWRzV/NnbHFjxpHE4OSZ+EzUDgy7Svx1fXL4mQNRQKjby1oq4g1J'
    'zYn1Zzg287ms5xTrLW2Yoz0KKT0NETpxjJynnusAX5wZG3wKDXQvU7LPSUUAM5fECe+s1kD4ulTJKv2OIQIFxrKnZL9lXMaf39iH'
    'cpmTFD1eLGKhqE2MPJWF+6WcK88Pt5CnBVbLDSLImaY2niMfL6S6dvfEyLO7JRj7vwOVwz8s8eebLe0LAZmkrEiMIBKNtjaFjPPc'
    'md22QkS83DeZxUKxe3zjcyXhC54S65LS2SxlcRAE2Whr4ylxukv4z+ktwy/shmDs9y4Ut9njKy5xahn/+pznPK/Z1hYJPCEZYEFg'
    'KcgGli/q2zA61cs9Aw5Gx6IYH36lEGLSUWJtyzepUKwQmGE8R0pt7YO+b9ev3jj29aU81/d7FyaAeaoo6dLNAYj+I5xSlqwCrRgC'
    'KCxKJKWAf62Nb3w6DVTNcttoxqWwhmLX6NCrpKSrlaRUKFYYRJCtQFtHiuNdR2zdPTr0nKW0MA58QUUNcZTEtY1WsNNRQkQNSxOH'
    'IKK2NtZ15AmAnaiPDZ5MFPYL6PbaFoI4nT2zbeRlniO3ChLHtAJjU6FYeQgi0fKNcZQ43nHk1TMTG59ESxTcP+AHxKXU2YtGb2PQ'
    '5z1HAeEM2kQSxi+MyWecJzHJiUdHh1YT9X45ODMTKhWeufriE6DxCVfJY31tTZoaXbkQQTZ9bT0lz5CE/9x95UVnL8XWh4O/eTn8'
    'gyVNttraF4RElX/vDRFkraVNPuu8RAkavX9ifb7n94+Uy2H8yDcXF7LO4+rtNJiZMhvcz3ry8dJ1J3aPbzh2sc/1Q8Yh4tmOM43c'
    'FwpZ9/frPRB5Z4YpZJSs+/rzvucMHzOweXe3q9+OhLj8fufkRf0Zdr/vOXJdK9Cc1lGkxISzdZSsNfXnC2uci/DaK5rhlsuFv6kf'
    '+qSrFgUNVI0U2BIYC4ATf6J2LAzPeYPXDj7dcUkSuO33oJRLBAAOu+cAeJyvbTgndAURDTdmBtvOL4bZ51f0b+E8j+RavwsNEWSt'
    'qU0h57yh9oj/kbBnVYkWo+vWoS/8gaplgHIw1/na/CTnKWJOYEXnXoRfYmBynvMqV4rP1CYveUw3q9+OiKj0XsCe4SnpGWt5ORdd'
    'MSJR6IgAMwGkJJGnpPCUEllXiULWkYWsIwu56M+MkllHCU9J4SoppAi7vO3xXmCbZBf6aCCCaDQD47nqj2fGh/6UqGIxtfD1Rod8'
    'QwK4OlUUNLi1Tox/sz00yTwWjKynXiFYfy1uX8bF5Pc7nAtBZCmcwLmsTvY9LmiwFQTKOEoUskoWco70nHDDrLH2kbY2d7UDfXuz'
    'bX5Wa/lfqreCz9Sb/jX1lj9Va+nrmr7+RTswd7a1vdtaritB4XvlQjHxlBICIMwRom7//AsIWWahrWUl5YeaYxsvWIwMybwumE4J'
    'dfUd+ZlG47s5Tz216WtLPRKRZ4bJeUq2A/0gA3+S3zD6WSD5sxvigpv6xPBrhRBfiBrr9ozIHQgGR0OUIT0loZQAM6PR0j4IdwLY'
    'QcB2Av3KWDzgSNzXtsHOflWw99VM++RLNzf2ec+J9flppowglqTVKazksQR9MoPWAVhHoCcy4/RCRkkQhbNatQ1nly6TUYzMbDOu'
    'Er42v4Gkl+YvXNhxn/P+guZUDw55rhpLWp+LQ2GZraekMJYNW/7g7bfVPvSkStWfmirK4kDVUgJN1PhA1yc3nWKs/omr5PGBNujF'
    'E7szVBgsMo4ipQRqzYAB/i0BP2Oi71ngRywzN6++6BOPHvL9ortmGUBlHoK/e3zDsQ7UOVbgBcx4IYDf85Q40VES7cAg0MaGVwNR'
    'L49CmA14Bp8v3HZ7EXixRaXCC3F+z18sYuvii5dka48G38x58pn1tu6prdAMtgQSWVeh5QdfNUR/0b9hdAcQzqIcSGCT1DgjMjMx'
    'dFUh422cafhGCOqZuEto7pOVgmTWUwi0ha/NLQC+yJa+ZAL6xeq3XfXInq8JM3BAOFqzuH0dx4OwgH3dMQ7di1nKJYrjPQBA4U7q'
    'PV7zyPiGUzPkPtvAvhbgVxU8Z61loOnrcPAzQfSwaJisq2S96f9V/8j4hxcqE3hYX0ZsXTQmRwakEJ8OjGH0kHUBRHc4Ys57jmj5'
    '5qHA8D/0P8n5Nzov7EYEJGvidXyga1uHngZL31ZC9AU90J07FglXCem6EvVm0GCLr4P4mgLMf9PQ5MNznkuoDghEorAYsZnwZlci'
    'VHcQ9rIkm1ObztAt8wYw/ogIz8tnHNRbAZhhon4uPSUazGApCWDUAxu8YtXQ5A8WwuU+PLEACKUSfRPfFOedecYXC1n3VUnspDUf'
    'LLN1lRRKCrT84L+J+P35DeM/BICpqaLcvn0dz8e8XQriAz09NnKJ69AnBJFoB9aAmBAOa0jMyRy7G64S0nUkak3/PiKqkrWT+eHx'
    'n84+rySq1R1ULHZnsnipVBLlc3dQec5x5utLqn7Xna8goj+xwKsLYaeqjkW61Gs8GiyzLWQcUW/p7xdazstxydHXXxz2SRafuPXx'
    'jeeRxDeIUNCaE3XCzpdwdgM47zqi4esmiMcky49mB6+6FQhFo7h9HSfB0ujsD5kYukgJ+Y8ZV51sjIWvLUxUiRCPbiAATNHGvygk'
    'uhQmNTOMkiQzrkK9FdxL4KvavthyzKYtdwKzA5nRJYE4EFwqCZy7g+bu3tw1PvxKh+hdDLwm6yo0/MCC4w7+vQEzTD6jZK3lf6B/'
    'aPzvj9YdOaIfPP7QmfGRciGrSjPNoKdiF/vAMCLyqest/RDDbpYaV+Q2jt0NzAbTqFJhdDEQGscvmqNDp2sh3kbg1zHoDCUpr4SA'
    'cqJDYEPtsMwIjIVlhuUwA9F5M2ICh7eaoxWS+M4bme+7iPEJgv5kbmjyLiBZonswGKDqVFEMzBGN2uTG14D5b3Oueo6vLQJje8aS'
    'ZgZLQQC4zkK8NH/RVT8+GnfkCMUCocu3dX3fjHG+mc+opzfavZNK3R+x+ewoIT1HotYK7gV40mEzmhmavLnzvKmiRBdP/LkHmyfW'
    '5+tCPp4trSXmExniHCZ2JeOJluh4AnsAncrgfMZRjpKzh0cbC2sZ2to9heQwRITD30zGlTIwFtbaqm/tB48Znvgl0DsisT/mZsn4'
    'C5fkao/6fywIf53z3LX1dmCjTFXirYx468NM0/96X9t7De57jDnSuNAR/7DxSducGH45hPiSZVbWoifdkbnsEZhzJOot/xFm+k9J'
    'PJodHPvB3MBYLBwLlZqa9xpLJYEycDCTkqeK8sEHkV3Vt+okI/QqZjqHiNdYS08C4SQwn0XAahCtyTjSlZGQWMvQxoZigr1FJL44'
    'QpeHCCLvOdRoB7+Bxfvzw1H9CpdEuTy/lGbSmdtcZnp8wzlCqA95Sr7BWAtf256wqBlsM0qJtjabCoOjV01NFeXAETTMOTrzM3JH'
    'pseHL+vLuu/u1WDn/ohFI/bBay0/IKZvWsbnXMv/ndk4dssez4/LyJdQPJhBe6cJAWA+nZN4dGh1w8gcufZ0Az4VltYR4QwGnQPg'
    'JBCfkHOVEOEIC2hjYUx47RMRXEei5WtYtqOs+W8KI+O/i9fTi5bEwYhTuWFTJVBj/OJLSNoPZhx1XL0dJN6iZrD1lBLtwNxBWfvc'
    '/MD4AyiBqHJ4LSeOUiw4tFSrF6+pt+z1GUc+pZcqO+dD7J4IAZl1FZiBZjt4lAjfB3Cdter6Qm73b/a+QPcQj3KFI5t+qawPilyE'
    'zma0jqAcIj3JpaLbPDNzIqR4rGU6hy09DuAnEdFZzHwCEZgZLQL9lMBX5YfGrgX2vAMvV7hUEvGNoDY5/HuwuDznOc9u+IFlkEiy'
    'SW2ZbV/WEfWW/mhhcPS9RxK7OOqfL/7Q3RPDz3NJfI2BvAn9kSR/d4cNA4yod7gSQmQcCQbQaAczzPglQNeTtT/0jfx1HP3f5z24'
    'JFCdc9EC6NZwpE7cqVzuWCblg6SLd227cI3nO6taAFwj/fymLfcBcUEUY6FKipNOnNGhgarZOXlRv2edf8q56pKWNtba5MYx4toL'
    'tlxnY19YGBm/4XAFY0F+sNgHmhkf+tOs63ysHVZrLQt3ZH/MKV0mJYXwlAQJQsvXMIYfBPBrZv4pCDcIpW7KwbmNDlLCHF9wqA6E'
    'FllxHceNh+LKxaUSFAaoXCpRuQyguoOqAPZXCxEXOfVaj5CFYq4lNTM+8vdZV/5tSxtmCyQ1bheWgjuy1vQn+obGhuaOvZwPC/JD'
    'hSd7aO7WJu68spB1R5ZT/OJghMLBDBCDIBwpyFUCJAg6sGgFuk2Eexl0Kxh3AdgO8P0C4rdtBA+ild19zKWbd8/jc2ifMQfFdQyU'
    'owAkLaqb04mPAEC5zCvFkjgYYaA5/C6mx4ZLniPL2lq2lhNpWTPAMvQjW7Dixfnhw0ulLtgPFG964m0XrqkZ97q86zxrJbaAmyse'
    'RExEQrhSQEoCCQJbhmVGs22aRGhY5vsF6H4L3ikIv2LQNAz9xrCddl3xYDYwD9wB4IyR8dahP5tprlsx19VZ4pjJimFuUHf3+NCf'
    'OlJ+hBlkrIVIomDE1kXLn+wbHBvsilgAc8qSxy8+Rwj7dVfKk9u6t3anLjTxXhRiChsoRJWVkoQQgqAEIU5bggC2jHpbg5kNET1I'
    'wEMEWCbcAuABtqiD8WtBcsbA7JLs3moDrQv3nPLQoQ76PtZJd4Kvy454G0QoGMN/7kn5z4YtJ7GUILQuAACtAPYlqzaM/3C+grHg'
    'P0gcv9g1OvQqz5GfBZALTDJVtpt0Wr8R896VlQQSFAZSQ4sEgAhbtwAcpjEBoBUYTeCHmREQ4RYGTTPjboK9mUDTmu2NUqgGB/xA'
    'X1/tkYNlK+KSZwCHzJik7AszqDpQFAPVqpkeG/6brKf+bxS7S9zu1di6qDf9bYWhsfXzjV0syg8RB3+mx4Yv9Rz5SW1toiPFSaPT'
    '/o3nbL7eT6m2ICIlQxFxpMDcr9cYi1ZgfGYYAt/LoEcZfDsR3cmWd0mBX/ls7iFVuONA/SP2sERSATkke1oYI5/qzzqbkhi7i2MX'
    'FtwIAn7Rmo1jP5vPvpHFEYs56aVdoyMf6MuqSjMILNtk7ZDsdaJ0LqLaB8TlFQj/SoKEIABKCigROYMkgLD6EIG2dQY/CNBNIDwA'
    'ol+S5ZtNQLcYo363v8BrZzt5QhsGdZuw9gh4eOv6Ppedzxc854JaK3l7p+ZYF/9eGBp753xckUW9cDs7JcdHPpTz1PtavjGWWaSC'
    'sTSEYoLQ1QE61knkzQgpQsvEkRQ1VmU02wbW8jQT3wvQzQL8C2tpO2B+09Lq9rWbtsx03j/hbQm7Rfy9PLJ142mu5f/ylHxC09cs'
    'RKIsa6ukEFqbB0Qgnp3btOXOQx3PxRWLqPCHiLg2MfKvOU+9q9HWifTjViJx8HWuiIBmRSR2cYLAwA9sHYS7APySmKdyt532+Xio'
    'TSoY+9KpPRobvEBJ9WUGMsZyomowmNnmM46ot4L39g2NffRQVbhL0eMgavZbFLVm/uOFjPP2cNde6pIklb1FBJEV4qhQQHxtYAxf'
    '22b/z9YMbr09FYz9Myd29758Rn2o4ScrM8jMNuc5ot7y/7fvNLyILhhvRc379+teLsnFGvdh4OtLqn73XR/NuepdjUBbTmBqKWX/'
    'zBUQIlA+44imH9xktHlT3/DE9oXsIr1ciGswbjnmEefE1bWvFDLqJQmMX7Agstbg9wvDW/7rYNbFkiw6CsARXVDRhcHRd9f94P96'
    'SopQwpI/sCglLBCNUroSgKg1fZ11nbMZNMbjG46Nt4h0e51JIs4cPeE9H28T0Xtavt7pSklJmpjGDJv1lCSybwIwW8i3H5ZM4ULB'
    'YGKA+gbH/rbZ1n8tiaCEELYHJpyl7AkRqVrT131577y6UG8jAu9Tjp4CqoRjM/sGt/zaWP4HR4Vzrru9rhgikB8YWNBr6ldvPOlg'
    'w5WX9ODGZiqXSqJ/eOwffWs3MXMj6yjBjGW9vXlZQhDGWGaLIk8Vs3G/h24vK3EUq5aZqUb6ikbb/CznKZGgEaDCN8bmPHUyLF4H'
    'AHv3R+k8cUmXhaisuFJhLpXEqqGxLb62b9LG3pXPKJkKRq9B1A4sAXhSo9l3bvhYKRWLvQjdkTI9ZnBrXQh8MDBsRJK6XzCxILC1'
    '/AbmkkCxul8h64rZSADH5tnqkfHrAm1e2fTNdwtZR4azL5NjpqUcGALAzJCCXAafCADV6v7vSisdotC8z9166rWBNl/MuU6SrGnR'
    '1pZg+bzW2B2nEoH354p01ceMp5r3j4z/JmjR6xut4Oqso4SSgtI4Rk9AwGzjXgAodnM1Cad67g6iSsVKwj81fd0UAoIPkKZcSohA'
    'gbbsufJYLfF8APt1RboekIqnPa9+21WPfPi3oxuafvBuZuzKe2EcI0mR45Q94TDtBrZcY5i7ABw0mr7SGRiomlKpJHKDY9831n45'
    '5zkEPrw+mIuIdZQEM70KwH6PY2JMRmbEved598TIsx3Cv2Y951mNdgAb7irpurCl7Ek8xKbe1l8rZGqvQbFq0+3uByeuY5iZ3PhS'
    'RfxVY6Gif+rqtchg6zlStAP724LMPJMu+sSjcX1U/JzEXIDxoniqKFcNjv6ore0r6y3/XwAEcfQ4tTISBROF2+UF6FM0UDXValGk'
    'QnFwaKBqGKCf3PrbbwWav5XzFHEirAsiP7Ag4PQZ3XpK+NiewerEiAUQBT4jt2TNyPiuwuDYn1lNr2609Y8KGUcoScQMkwQ/byXD'
    'DGZmk8+5shWYT+d++9trmZmOZBbFimSqKC6ofEsrwpVB2Juk69chhdsNTT7jSEV4NgBgr2B11xe5P6hSscwgLpVE38iWb7QC8fJ6'
    '25QtY1choyQBlFZ+Lj2hSMBIQVTIearWaP9ACPfPqfIt3e219RRRajIrgq+2A/PrjCsTdT5bwrMAYO8UaiLFAgjdEqpU7NRUUa7d'
    'tGWmMLilwswvbvq6CoDD1BPbJH3JyxXGHJHIOtJartfr/kdNRv5BYcPm+9N9IYcHEZinipI2bJsWJD6rpNizuVHXFsaktQEzP23X'
    '1MXHxNs04n9OrFjEDERVgcwlURgc/UVuw+gAMb+x7euf5jxHZJRKRWORiC0JQUSFjCMtc6PeDLZpwxcUhkffu3rgqkfCIFgCTvRe'
    'oxhmGzTjy/VW0JQCsuvuNRP5hgHQY6mtnwBgdkgVekAsgMjKiIpamEH5obFr6z5d0PCDd7UDfVM+4wgvFY0Fg5mZGUbJ0JJgy36j'
    'HVxN1lxQGBpdv3rj2P/GxyJts3eEUIUZoFWnPvYGgH/ouQrU5UAnEciytTlHuVLLJwLYo96iJ8QihioVSwSOXZO+wbF/s6r9gkZb'
    '/5Vv9K15zxE5V4moQ1QaCD0MQlcjFFvXkVTIOtIYfrTWDMastS/JD45elB+e+DGXIOL+FalQHDkEMKaKgi6oaLD4qgCBwd0vZWBi'
    'IQmQ9kkAOhYQkKA6i8Nl7rBaAJiZWH884LwF4A1KiPMyjkTD17AWJu6Y3e01J5F4ADQRZM5TYGY0fHMvLF/NJEf7h666MXze8hx6'
    '3E3iJrmN8Y3PtcTfJIJrLbibPV7m1M58ufDbU1+HSiXuopYAJTtK9haNu6aK2WOb+VdYwiYwvaqQdVSgDdqBjUYOYsX3AO2MXyQm'
    'V0rhOhK1ps8A/UAQroaiz+UvjGaZRnsEUpFYeGI3budlF/Vn1jg/9Bx1TivobjctBtuMo0Q70Dc3fXHe2k1bZuJ1qkO/PNmEpnC0'
    'NToUjSaAawFc2xgden6t0b4QJF7tKnGG60jZDgwCY2wYfWaxcsYTsGUmBjE5SgjPUVKH4wJ+5xv7NSjaWjjp1G/SBRUNpCKxFMQ9'
    'XohoujYxfIOS4hz41N1N/kwUzqWh4/scOgXAjWGQs9L7YhGzH9EwuZHx7wH43v0T64/vt86LgpZ9I8Avz7pqrRQCfmDga9u5y2IZ'
    '9QXdq4+mcB0pXCVhLaPR0g8H2v8mEX+p4NA36K1jd3deN1WUKE5ZIkpFYikIh2EbZvEDZn5rOLGui6cgAcYypKDVgbEnA7ixGgU5'
    'l41YxHREIx7WXAZosPIggM8C+GxzYtMZLd+8RMC80gDPc5U42XWkNCacpWGsteGQ494Sjz3EgZikEMJzFAlBaAcGfmDu8QPzQ2b6'
    'Olu+ftXGsVvi15ZKJXHuuTuoOFC1oTvXEz/y8iAKILKxNzTarAWRsmGksysHIS54dJQSAQdPAPDf8U7iZScWMeEMgjA405msFd4x'
    'bwdwFYCr+OqNJ8349nmBtucz4QVgnJ3POFkigjEWgbHQhuNYB2IBiTZLdeVg7jELZE73bSWJHCVJChFaD37QaPh2B4N+ANj/aQfy'
    'x2s3hXEIYPY7KW9fx/MZXZeyWEQBRCNvZmnudZU8LZyW0UX3mImlJKBNZ8x9eNmKxVxiayM0NqKZnsWqJdpyHyKLg6+4JFfP+U+s'
    'N4MXUlgb/2QGTnOV7HMdKQHAWAttGMZYWLDF3Clg0cBjMCg+ztHRntdBnx1ZGP2299jC6P0FkZBCQEmieKCyHxgE2k5rY24F9M8F'
    '0Y/J8I8fAn5zxshYZ/p6RzS3r+NwVF26l6PrRGdHYdX0znqrcKcS4rR2EnriWAaBzwEADIRl3yva3uyM4tu+jvcO5D3wb8XCqlWF'
    'U33LTyTBT4GlJwmiMyzzYwl0TNaTYXvyaJ+lMaF2WMvQ1nZasnbcA2C26mOvb31u9FsQQQqCEARBswOR2XKc1tQEngbTvSDcxoxf'
    'MeMXILG9Lzt9RxTgnf0ZO+I4ZdNKy2QSl8vXJka25TPOhd2ejxoPH2q09Q/yvz31BVSpWAZoRVgWByK6eAwwW0cw58KqAdgR/fpP'
    'AOArLsk1+/1jSYuzGn5wMrM4k8BngOgYZpwpwFkmKoD5OCJSRICrBAkKZ0J3DMs51WKWGYG2iPbfs7HcMGx3QVMDsLuYxG0E7CLL'
    'tzLhPgbdq1y+s1YXD88dJRjTEYfOIONYBFf0fSHRVDtBTtx3yCcvBYT4fMw+uHZHDkANvELckPkQuiqV6BqmPcUDQOi2bG4AaAC4'
    'e+/X8xWX5AA4u9z2GiHkY8jCIYdd7du1Fpxn4qwgoSwAGBjIUKQIVNds7xcsmpCWBWiarN2Z02oa9X6f3vPx9oHWvP8p53MspMrC'
    'fDcpi0scQBTMd7JloHvxzRAm0oZB4JP787njANRQLq1sy+Jg7CkeIcygcrlE5TJm9/pvX8eoVJgu3dyInrYbwB0LtY5wKneZOp9X'
    'XMcoA6EwxLGYiFQcehpDuC/M5HffDIx6ZmfJRSZ+LBWLwyAWkMp+LsrOVt5ymK6Nu1zPp4Ftdc7fi9vXMcpljs+XyFXaN9aQCsPy'
    'IUqfKtDDvjZh+rTL5gUzwCClLXLxY6lYLBCzm6oqfNQX8v7UKGX5Ug7/sIJnmOELEgqWuyYVRCBjmZWkjLV0KoCf4dwd6eaqlJSk'
    'oFlPE6OViPlDxOw5EsaYY+OHUrFISek25XLYCIe4BZBOxHalTpp/djGpWKSkJISskYmug0nFIiUlZV6kYpGSkhR8kwD/48CkYpGS'
    '0m3KZQIA6agCE3s2oXPB09RpSkpCMFKsIsBLilYQAJBIA5wpKYmh00FbHK+kyBjLXe3DGUG+tpCER+IHUrFISUkIzLw6mrfXVduC'
    'ARaCyNdGG20fBAAU1y2ftnq9Cke71lAu09wZDYjLvsNbTEIM05TFhU8VFB3trvbhDMsrCAg0uA4AKKcxi64RbyWngaqJ9q7vZ/9H'
    'WPbNU0W5v54bKcuD8vZwbwgJfkJYA9X9viPRMnTWEfX4sVQslhgulQQqlc6Fz8yErZee2ODgVAt7BiAhiNuwdHcua+6hgfHfxWMO'
    '0tkdyw8GiCoVy1NFWW/hTLaMrjftBYNIAIxW05hOi4RuB1FWDPGu1HjDWX1843kW/AcEvJDB5xDhmIyjPBBgDMM3tgXwwwT6DcDf'
    'AejzhcHRXwBzBCd1T3qeeCbHzKcuPgGu+ZHnyNPa2iRidkirrW/UzM9bMzK+i5nTjWRLAZdKIpzXCp7eOvii2uTIZ5n424WsU8pl'
    '1EtcJR9DJLxmoG3T19bXliVRxpXy5JynXprPuGUA361PbhyfGRt8ClUqlgAuRbM9UnqYaPCwcPmxAE4MwsHEXb2JExNLQSCBh9eM'
    'jO8KH6TUDVls4rmgu7ZduEYZ74OC8bas6zhNX6PWDAwBYLAIA5mReIezG9hYi0BbywCkoELWU4PNNl5Xmxj+cL7p/jNdWgni9+/q'
    'D5ly5ERBbRb23IxSXtPXLBKxkwwASM/9v/TOtIh0hOKqkTNd430ln3XewQyn1gpMlEuXIMiwQ+eeLiERosadkESQxjJHjVxX5zzn'
    'Q81cUK1fufEkqoTT5bv1M6YcJVFwk5meo6QAofvDnULbhoCw/2w4kxXg9CRbJEqRUOzeMvx4x6XPZzPOc2rNQFsGUygAh3X3CMUD'
    'UhvL9ZY22Yzzerj8pebo0OlUqdjUJek94uDmzZe9yyPmp9tOcDMhxA2Eo65v6Qm2CJRKJVGpVGx9bPBkpWgq56onz4Quhzrayryo'
    'UbisNX2dyzhPNyS28dTFx5QrFQ77dab0DKUwXnHqMfXTGXiirw3AiXBBhB8YkMBNwGzbx1QsFoEyQhfEkPhoLus+rdbytVjgORAE'
    'UrWWr/N553kzDf1PBHQ2JKX0CFG8QrN+dsZVq7SxXS/zDqs3Qb42Ghx2sS9GPUJTsVhgmEP3o3bmnW/JKDlQb/oGRIs0MIZko6mN'
    'o+TI9NjIm6hSscypO9IzFKfC+ASLVyspgATEKwjMjhQgonssgtvDR8upWCw0Yc68wrumLj4GjA+QIIQhisW5WxBAli0pKYgE/x1v'
    'u+Q4UOqO9AJhOp24PrnpFAt6sR8YIAnXIxMrKcDgmwu/PWsngE4mt/uLW0ZUw4E/7LRwYT7rnN3y9aIX1xCRaPnGFDLuOU2jh8NC'
    'rdQdSTyRC2KNeWHGkSe2dfddEGA2E0JEN8eZtrj4LxWLBYIBGhioGh4dyljYDeHtfalq/JmMsazZXnT/xPo8UaWLjeRT5kUxHDYs'
    'JF7jKAECuu6CAAgrsizDMn4FAHM3N6ZisVBEke0GOecC/NR2YImX6PslImoFBkqKp/RBvhAAYaqYHtuEElf07rpq5Exr+ZXthLgg'
    'DDARiWagA2i+EUCnDgRIwAKXDXElntRPz7rKM2ztEpqVxAybdZUA0asB8NyDnJIwonNFOnh9PuMcF2izlOfKASGAHSlgGb8jpW/a'
    '+99TsVgo4ko8i2dKKQBe4m3GxBRoC7b06l2fuviYMDPS/RMwZU8YIAxULU8VXVguMndGVHYdZrArJcD8077BrQ8yY48dzqlYLABz'
    'txkD9CQ2S1+JRyDRDgx7jny8dOzvA0BnwnpKYqhOFQUBPN3Mv0wp8cymrxlY2Bqco4IAZvwvgH3On/RkWgji+0I950Bw3nZv57hV'
    'ksDEF/NPLnFQrKaBzgTBABWLU5anilKA3pVxpLKcjPa8YbwCotkOrJDiJwA6A5tjUrFYSPIN4m7GtAmi0dbsSPGC2vbgfCJwGuhM'
    'EFwiIuJ6q//lStLL6m3NlJgdpsyuEqQt3219/nn4WDkViwUnPtzbYYiIuxWrCou0mDOOVCC8k0slge3rOLUuuk94DMrMpZKw1r4r'
    '40rFDNvlllizMLGjJAThO/0Xjz5UiorG5j4lFYuF5FwYMGa6efSJiBptzZLoNbUz73oJVSo2TuumdI/qVDGs2Dzzzlc5il5Rb2kG'
    'Jej6iwPkENcBQHlu8+iI5Cy2hyGAuVQSNFA1BPyCJC19NmR2LbPWBfj9/JV3eWXMtvVLWXqYQdu3r+ObL3uXx4z3eY5UUU1+Io5J'
    'lAURfqAfECS+BQD7S72nYrFQdJSYfmm6kA2ZCxGJuh/YjKteVH9oerBSqVggtS66RrlElUrFnrS6Ppjx1Asa7cASJaqlpXUdCYCu'
    'z2+48h5m3m9T6CQtuLeJ6yyM/WHL1zUlhGDubkNdZgZDvI+nhk4EVTjtqLX0xM2VeXToRBD/DXf7pNgfxKSNhWF8GQBQHdjveZKe'
    'PAtFpcIAUAjc3zDzL1wlAXQvLUYg0QqMLWSdM2p1+gABXN2PH5qyyJRDN7Um6AN5T53eCrrbuXtvGGxdJUUr0HdJtv8NoLNvZW8S'
    's+hehwCemipKunRzQISvC9H9YTFERM12YJUjNtUmhl41MFA1U1PF5BQALXOYS4KoYusTw691lNjU9LVNTqo0gonDGxu+UhgZ/128'
    'b2V/T03FYhEg0HX1VtAWgiR3cbYHAWQsQ0nhgOkj01eNrC0OVG3a72LxCS+6iq2PXXoyA/8iiBwTRpkT9d2HhVjagOk/AOyxy3Rv'
    'UrFYQIoDofl276OFG5j5hozTXVcECIOdTV/bfMZZB8X/GPe7SGsvFg8GCOWotSJaH8lnnDPbgTVJcj8iTMaVZKz5WSG7+nsADuiC'
    'AKlYLCgEME8V5RPe8/E2CfqyENRlqYjWRUR1X1tPyZHpiZG3E1VsWtm5iEwVBVHFTp95x7tznvPmeiuwlKSaighmpnAQM22jgY81'
    'eaooD+SCAKlYLDydrIi4tt4M6kp2PytCALFlMpbZEfTPu0aHXkUDVcNp/GLB4amipIGqmRkfeZkr5f/1teWoxiVhllwY2Ky39P1C'
    'qv8AZgc0H4hULBYYqoRdqgq56e0Avp91JCehCxIRkbGWlRA5V4pPtbYNPZEGqiZNpy4ccWFea3Lj2VLQp6QQOWNtgvZ/zMJM7DoS'
    'YHwuv+HKezgaX3Gw16QnymIwVQyrOYX4D8sgTsjgmKgLkvVceYo2YmLmUxefkE40Wxji6XMzE+uPN8zbPEee3gp00oqvAIQ7TKUg'
    '0WgHdSK6EkA4v+IQJO4HWRZE5lwO9OV6O/idK2XXXZEYQSQabWPynvNMcu0kjw6tTgXj6IiF4tHRodUCzmTOU89otLURCRQKAADD'
    'Zl1JbPmLhaEtP4+60h/S+k3mD9PjdLoib7jyHkFUDUtpu++KxBBB1lqByWfUy+tCjD505ca+VDCOjFgo7rz8wjWulFfnMs4rai1t'
    'aIGHSi0gTATRCoxmwqcAzLtJUnpyLDJEPNloBU0hSHSz5mJviCDrLW1yGfWGjGuv5m1vXzPb7StlPnCxKGOL4piCd00uo14dDa9O'
    '7HfIDJvzFGnN3yj89vZvM4dt/ubz2lQsFomwByZTbv3oTyzzdTlXETg51gUAgCAbbW0KGfcPGrb1mekrLjkuzZLMD54qSqpWzfQV'
    'bz3OleLThYzzyqQLBRAWYbUDo5Xgj1DlWxrVYmcuyKFIxWIRqVYHBBGxInyi6WsT5doTY11EyFozMDlXvVxmg88/Ojp0eioYBydO'
    'jz64ZfjxIpv5Qs5TPSEUzDB5T1GgzX9lMvX/YWaieVoVQCoWi8qbB6qGAcpk6t8y1n4v5ynipFkXiGMY2mQ99XzXkV/ePb7huXFa'
    'Ne2DMQszKE6P7p4Yfl7eoa/kPPXchMcoAEQZEAlqBrrBJD9IA1UTTa6b980rFYtFhBF1SBqo+sz0cV9bBiFRsYuYOIbhSbHOkc4X'
    'a+NDG6hSsURIt7YjsiYITJWKrU1sHFagL3lKPq7eA0IBIMyAeI4IDF+zamjLD+K9K4fzFiv+JFhs4o1bfW3nWj+w/5X3FHFCOjrv'
    'DRFkw9dWEB0rpJyoTYz8y71XXJKLA58rcT8JM2gqcjseHR1aXZsc+bgUGJVSrGn42vaCUDBgHSVEoxk8AJgPH+n7pGKxyBDA1eqA'
    'oEs3ByT4w61AByKs6EukYAgiERhjrWXOZ5z3rMr6185MrH9S1DJwRVkZsTUxMFA10+MjL/CUvC7vOe/UltnXhhNbR7EXxGBXCbLA'
    'P64amrw5Tvce9vssxuJS9oWZCeUy1c6883OFjPO6pPu5DDAYNu8p2QzMQ5b5g4Wm8wm6dHPAXBIohxmfbq9zMeBSSaBcYSLwA/9W'
    'LOT7Cn9OAn+VcVSu0dYGBNkrFw4z25ynRKMd/G9jJv+S4x9a24h/tsN9r55QxuVBmahSsUKof2j4piklUVKqOvcHAUQEWW9rIwWt'
    'zTryskY2+FJ9bPBZRBXbcU2WUW+MMKAb3nWJwLXx4Vf29Re+nsuoCoFy9XZgqZeEAmAhCL62AYj+zwnvvLwGAEciFEBqWSwpsfk3'
    'PTb8sb6c+6czTd/2ginL4b5JznuOaLZ1jZk/JaS4LLd+y50AMDVVlMXt67hXLY3YtYrXX9s69DRi8RdgvDnjKtXwA4twO1hPXS/M'
    'MIWMI2tt/5N9g2NvP1L3I6anfvheJ+7+Xpv847XErW97jjq7pXWiejIeDMtslRQi6yjU28G9YHyChBzPb7jyHiA23wHgyMzcpYQZ'
    'VK0WRbFYtfFaW+ObnuBD/4kkGs55Tn+9HYCZE7kZ7FAw2GYcJdq+vimv6YXYOLoT4KMawpyKxRIT92WcGRsZcB3xmcAYC1AC+x3s'
    'n8h1sq4S0lECjba+m4FJR/NYZuPYLZ3nTRUltq9jVCo83wrBxSasGSkRqjsorDMIqW0dehqM3ATiN+czznEtX0MbNiCIpLXBmw8M'
    'sCCwJMGGgz/Mb5j4QnzeHc379twX0eswQCiV6Jv4pvi9M86o9ufcN/RC9d/eROlfdh0pXCVRbwU7mflaWL6mMN3/XXrPx9ud504V'
    'ZThkd2ktDgbCVmXVAYHiOp57sdw/sT7fz+plTFjPTK8qZJ1COzAItDUARK+5HHNhhilkHTnd8D+1anjskoUQCiAVi64Q+467xgbP'
    'cqT8b0eK09uB6UlzF2DLTOwokp6jUGsFFuCfEPCfDPHlwm8fu2Oun8wMQrUoqgCK29fxkUbm91kFEL5LuURx09m51gMA3HvFJbk1'
    'efN0tvxqy/YPpBRPzboKTV/DGO55kQBCV7HgOaLuBz8xbfnKVZuuevRo3Y+Ynv5iehkuRhuRxkbe6CpRNWzJMqgXzV5g1j0hgsy6'
    'CoKAWjuYIcZPraD/cWC/k/G8n9PA5t37eW3HPeg8eIgWb3t0od7LapjLw9cMP9bz6amW7QUk6AKAnlzIOMoYi1ZgwIxlIRIAYJnZ'
    'VRLM/JCAeKW3/sobjjaoOZee/4J6GJqaKoqBgaqZGRv690LOe0cvuiN7E5ayMxMTS0nScySICLWmb4noZgZ+JYi+J9j+ClC3Z0xw'
    'P42Mtxbis3dedlF/4Rj3FF/bJ5AQzyDg2Ux8rhLipIyrYKxFOzCwFgbE1CuB5fnAAEsiKwXJVmCHVg2PTsQb3hbqM1Kx6CKdTVrV'
    'i9fUW+b6rOs8pd4OeiKdOh9Ca4MZIBYE6ToSSgowMxptDTAeZMK9YL5NAA8z+FZBdIdl1C1oGtAPO+S1WNjwzmgUCzQzRohjGPJY'
    'WHOMBU4lEqeDcQoRTmfGSY4S/Z4jAWb42sI3lsGw4fxZ6lnr7WDEadKZpv/x/uGxd/NUUWKgahcyuLzsvrReIzYTG1svfj6x/TKI'
    '+gNjIRLY5PVoiC0OMHF8V1dSQEmCFCKsi7cMYxm+NrDMAZiaRKznTnZjZkWEjBDC85SAIAIEAZahLUMbC204dIkAMFgksWHuQhIH'
    'NGst/6uFzJo3ofixFnDkxVcHYll/ib1CbC5OTwxd7El1pbbW9nL8Yj5E5eQARQISPkrhyC6KNCAKJMy51pkZlsNsDMeRkmhkPRNT'
    'LxZPHQ02Kuf2A/Nrhnx13Kl7MQrkVsyXmnQ6gjE2/OG+rPOX9Va4B6Hb6+oWHTE5ACtJEA4EM1vPkUIbu9MP+PdXbxz738USCiAV'
    'i8QQxi8Yd4wNe2uFuCafdXqy/iJlabDM7EhBAM0YqwcKg+PXLXRAc29SsUgQYUt28PTUyFrR4i/lXOdZ9Xayd6emLD2WmZUQIILR'
    '1gz3DY5vW2yhANJdp4ki7krVPzD6kIR6S8PX2/OelFEtQEoKLDNLQSACtDF/vlRCAaRikTioUrFTxaLMDl55O1vz5mZgbs+6qWCk'
    'hLkkJYilEOQb/su+ofGPc6kk5tvK/2hJ3ZCEEt8tdo0NPcNT8lpHipObvkldkhVKZFGwI4Vote1f9Y+MfphLJbGUG/VSyyKhxO34'
    'Vw+P/zSAeXNg7D1ZT6UWxgokdj08pURLm/d3QyiA1LJIPHMtDFfKqYwjzqy3UwtjpcDMVkohBMHqwL6/MDz2oblt/5ZyLalY9ACd'
    'GozJkXUKdHXWlU9Neg/PlKOHGcZVQlrLzcDYd/cPj13ZDYsiJhWLHiEWjMbWjaex5clcxnlhrRn0bIOWlINjGSbnSekHZmfAvHHV'
    '4NgXo74UjC41E0pjFj0CDVQNc0nk1m+50zSdP6w1/C8VMkoSMduEziFJOXyYwcwwfVlHtn29I9D2tasGx74YjiWoWHSx61gqFj0E'
    'UcVyqST6L928cydzsdbW/+RJJRwpyDL3ZLPclFksMxMBhYwjm37wX77h16waGf/hUtVRHIrUfO1B5tb/T48Pv8OR4h8cKfrT1Grv'
    'wgzjhPEJWLYf2d10P3DypZsbSREKIBWLnoUZhHKJqFKx0+MjL5CET+Yyzrm1lm/DLmrLe1v2ciHuMJbzlGxr/Yi1+LPC4OgEsOdN'
    'IQmkJ1SPE9956ldvPAkaH/McMRAYi8DYZdNEZ7nCzFYIEjlPodnWP2bwO/Mbwp2j3UiNHopULJYBsWAwgxqTw38CIf4+q+Tqelsv'
    'm/6Sy4lZa0LKVmDa1uLjhZbzQbp08+4kuR17k55Ey4S5JuuuscFnOVJ9LOep5zXbAYxFGstICMwwUpDMhtbEDdbgrwrDW/4LSJ7b'
    'sTepWCwjGCBMFQUNVM3OyYv6s+z+LYjelXVlpt4OLBB2oer2OlcijDBblXcd0QxMC+DLgpb48Oq3XfUIc0n0whS3VCyWIXOHykyP'
    'j7xAAJWMK18S9rfs/SE6vUQ8jCnjKgEAvjb/Y4yp9A9PfDv894UZALQUpHeZZQhRxTKDuFQS/UOj382feuor2759t7H2vkLWkVIQ'
    'McNwQsYKLkfi4ipHSSpkXNEOzI1tXw/f7tVe3T888e1wYjuoV4QCSC2LZc/UVFEORAGzXVeNnKkcvBfAxnzGydRbQThkJy0ZXzDi'
    '4KWUJLOuQqMVPECEf89afTkNTT4cPqd3rIm5pCfICoABqkYDjQBg9/iG50qSfwnQ6/Keko22hl1Gk7m6QehukFWSZMZVaLT8GWZs'
    'lSQ/mh286lYgmvm6wLM8lpL0xFhBcKkkgLAbFwA0J4ZfYkDvAfCafMaRzbaGsctj5udSwWALJnaVkK4jUW8Fuxj4NKz5RN/wxC+B'
    'eDB01SY9gHko0hNiBbL3NueZyaEXE4u3MeONhayTbQUGWluznCd4HQ2xqwFAZF1JUgjU/eBetryNYcb6hyZvBPYV514nPQlWMMwl'
    'AZoVjfrk8DOtpUuI8Ia85xxnmdH0dTQ8ePlP9joYe89wzTgSgWH4gf41ICaEsZ/ObRy7G1h+IhGzYg9+yix75/l3bxl+vJT8Bibx'
    'RwQ8K59x4AcGgTGW54wf7Pa6F5u5IxcFQWZcBUGEWsvfTaBvC4GtDfjXHbdh2zQQfY/l5ScSMalYpHTY+47IU0W33sxfwMBbALwi'
    '46qTlBQItEFbL89hw3GgkgCQgPQcCSkEwkZD/HNi+rwS9NnMhi03dV4zVZTl7eu4skxFImZZHOCUhYVLJYFzd9DcPQo7Jy86xWN1'
    'viB6hbX0IiXp9IyrYIxFOxxkbOOhx70ybzQckcjRX4lBEK4UFNVPodbSPsA7mPANWPuFh5l+fMbIeKvz+mUSuJwviT+gKd2DGVSt'
    'FkVx+zqea1pPXzWylqV5roB8JROfT6DH5zPKJSIYY+EbC2tt6LIAiAUkHHrcnXOuIwyEaBAzE1E4yd1VAkSEpq9hrL0PwC8I9E0C'
    'vpXL1H5JA9Vm532mihJ7fR8rhVQsUuYFMxOqA2LvC+WhKzf2uS6vE0zPIuLnwPJTGHRGxpN5JcM7tDYW2lgYy51UY+eNiYkAhD2i'
    'gMMVlE4VavyONDtZfc7TBBHIkQJKEoQQADPqbQ0AD1jmGwn8I2voe8pRP89vuPKePX/2UhSfSf7+jcUkFYuUw4YZhGpxH+EAAJ56'
    'R6FWa5whHXqSsfw0ENaB6XFEfDwRHZNxJIQU4cXNDMuAthbWhjd+G9ZJMw52UTKiMzeMlRDNFoYIQYjmgAKR/vjawNfGEuMhJtxD'
    'jBsFiV8YMj+X1t6Sve3Me/b9OUILIol9JbpFKhYpR0XcsQvn7qADmecPXbmxr88JHhOQPIVBZxPjJACngHASmI8F0Vow94HgCRI5'
    'RxKICFIc+PRkZgTawjDDWtYgNIkRMNE0AfcTMM3Et4FxN0PcLoW5ux3g3l3A7+bGHTrvN1WUABAFKrvWQTvJpGKRsqDsIR4Iu5If'
    '9PmjQ5m68tZo08pJIE/knMLE/QAkgzP7e40AYJi1YprWhMBR2KV9u9NxhW9828iffsdOuuBb+oCfGQVwqwC2b1/H5S7N4eg1UrFI'
    'WXQ6AlIGUA1FBMUpS0SLeoHGohB+3joul4Fy6lYcMalYpHQTYgbK5RKV40fii/twKK5jxG9QLjNm87apKCwg/z9TVvDkFDjXwgAA'
    'AABJRU5ErkJggg==';

const String kGoogleGLogoPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAACgAAAAoCAYAAACM/rhtAAAABmJLR0QA/wD/AP+gvaeTAAAFWElEQVRYhc2YaWxUVRTHf+e+12k7pRRaOwUXJMYt4lKslUrcKIhBI1FxUKNpcE3ED0Ri3HCpMTVucYGI0U9GcGtVEqokKgx1V1qNYjCIogaUUJBCYTrd5t3jh9KmtJ03b9rS+E8meTnn/+75vZv3ztwcYRjSaNTZs++vGUaYo3AeyikIk4GCHofEQfcI/GHhJ2P1cy+ra8OkTza3ZVpLMjHvqpx+YpY4ixWpAiZlWCsh8IHA8mM2NDaOKuDuuTMj4nU/IXAr4GYINkgqrMXapSWx77ePGLB5dvnNwEsChSMFG6CEoEuLNzS96mdKCajRaaG9LbkrQW4bZbAj68BrkcKpi6Wuzhsqb4YK7p57dt6/LeGPjjYcgMDVu/fuPCFVfhCgRqeFjJe9RmHO0UUDYI9nqZzc8O1fqQyDXvi9LXmvgF42jGKKcODw1QTSv989cBsbt/iZjtjBng9Cbw1OxC+oPCBqy4oLEzmR9Y2FkfWNhcWFiRy1UipwL+jm4cJBv6fcPXdmxNjurSgTA4DtQHRpZH3TBwKazt9cef41IrocOD4TOOi3g47tejwIHFAf8rrPKVnf9H4QOICS2KY1XUgpyHuZwMHhHdRPc6e0/xbe3rZuiqvtqfuwKm9FiqZWpWoJR0MGICne3VmnHnTHL9qGU9Kego6vIq120VjCAThai2NzndeBfMnxCJ25HxvPwmvO7e9LeNaZk/9NY8tYwgGY5AS3AnRyb0CyLHlX7iDvip2Ia3ujL/r1qqMKiDBrqETonH3kV/2GmdDVqcjysQbrlQuUp0o6Je3k3761IXteZ3PQBStr4k+NChlyKLYsr8ZF5DQ/m8nyYhmufP8IqPpJvbJX9RkDHOtnE9XAPWuU5eQfaC8xQJ6fyxqzd4yABsnttBOHPG79X+S5JmyAuJ/JWFs8RjyDJBY1CLv8TIqcMVZAA+Vo936D6q9+pkNkzRsroAHSHG/8PwalKZVjW7KARQcuuWjGW/NLgq7aZZKFQX6I3JlmqR311ZJwETYATwzM1ndM4bm2s+hSx1WRJcBDQQC/fHDC/iC+WU/GL/E7cgvSBGDcL5Pfgfa9h13qUHOolCfjpXSp02MWXVL+5oKTghQOosuebjtWlAV+Hqs2BmCkGouYNwB2eWHuaL2QDzunDPSHcXjz5HXzskcDMOnp80COL1+WsxYOnwfdpLPy6+5I/JbWi9mWLBjyDoWKgtbwG5duvHREk4XZNfElolzv51Eh1nB/+O8+QLm8fee9rRWrDtqQ7+IiLIw3F629oDaa+ZRBVSpr2pYpvJDOapCX+mr2XkyvjRY71m4l0IhDdgnc17j1zLeprrbp3DNqo2fYzoIVuf8uqnQTpensm2IP5VUgokcAApS/c91Niq5OD9in7YiuMuJ80tGRs3lz1ao2gJPXzcsuiI87VazOBL2WniGAASF7/3yyW64mxVDDQ83M2MPhTb2BQV962dsLXhPhjgwg+ysOWGC8n8lNTCN3z12Ilz8gozWxZfkP948MfoyDRXcLfDxMwHHp4ACS4S3ET3gUL+f3vpjAx0WnjHtsoHfIXllWf1VY2kJrgLnDBA0kUZfsfTcQap3zte1uv7yhOjLo4JKymU+rjYZyrV0BpPtLGinkF90dFfN/vOWeA0Pm0y1w3rsLbsSyAqFolNk8gWfzSvY90jCrIZnKFGgEPL02Wuxa+7jCbYB/swymz60xS39YWPd9OmNGQ/QZq689PumYxYhWCRyXIVSHQD3GvNy4sO6zoDdlBNin6mpTdtrP5YLMRvRc4HSUSQgT6ekMBxWaBf4EfhLhi4SYjVsW1vme3ofSf4An9u/kR1AQAAAAAElFTkSuQmCC';

const String kGoogleServerClientId =
    '1034344193488-b1ahotfvo55t8br81e03m6fp1a9i4hq6.apps.googleusercontent.com';
const String kRewardedBuzzAdUnitAndroid = String.fromEnvironment(
  'SUNDAY_REWARDED_BUZZ_AD_UNIT_ANDROID',
  defaultValue: 'ca-app-pub-3940256099942544/5224354917',
);
const String kRewardedBuzzAdUnitIos = String.fromEnvironment(
  'SUNDAY_REWARDED_BUZZ_AD_UNIT_IOS',
  defaultValue: 'ca-app-pub-3940256099942544/1712485313',
);

extension FirstOrNullExtension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

DateTime inicioDiaLocal(DateTime date) {
  return DateTime(date.year, date.month, date.day);
}

DateTime proximoRefrescoCambioDeDia(DateTime now) {
  return DateTime(
    now.year,
    now.month,
    now.day + 1,
  ).add(const Duration(milliseconds: 250));
}

class SundayClock extends ChangeNotifier with WidgetsBindingObserver {
  Timer? _timer;

  SundayClock() {
    WidgetsBinding.instance.addObserver(this);
    _scheduleNextDayRefresh();
  }

  void refresh() {
    notifyListeners();
    _scheduleNextDayRefresh();
  }

  void _scheduleNextDayRefresh() {
    _timer?.cancel();
    final now = DateTime.now();
    final delay = proximoRefrescoCambioDeDia(now).difference(now);
    _timer = Timer(delay.isNegative ? Duration.zero : delay, _handleDayRefresh);
  }

  void _handleDayRefresh() {
    notifyListeners();
    _scheduleNextDayRefresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      refresh();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }
}

class SundayClockScope extends InheritedNotifier<SundayClock> {
  const SundayClockScope({
    super.key,
    required SundayClock clock,
    required super.child,
  }) : super(notifier: clock);

  static void watch(BuildContext context) {
    context.dependOnInheritedWidgetOfExactType<SundayClockScope>();
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await FirebaseAppCheck.instance.activate(
    providerAndroid: kDebugMode
        ? const AndroidDebugProvider()
        : const AndroidPlayIntegrityProvider(),
    providerApple: kDebugMode
        ? const AppleDebugProvider()
        : const AppleAppAttestWithDeviceCheckFallbackProvider(),
  );
  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
    unawaited(MobileAds.instance.initialize());
  }

  runApp(const MyApp());
}

Future<void> crearUsuarioSiNoExiste(User user) async {
  final userRef = FirebaseFirestore.instance.collection('users').doc(user.uid);
  final authDisplayName = user.displayName?.trim();
  final initialBaseName = authDisplayName != null && authDisplayName.isNotEmpty
      ? formatUserDisplayName(authDisplayName)
      : 'Usuario';
  final authPhotoUrl = user.photoURL?.trim();
  final initialBasePhotoUrl = authPhotoUrl != null && authPhotoUrl.isNotEmpty
      ? authPhotoUrl
      : null;

  await FirebaseFirestore.instance.runTransaction((transaction) async {
    final userDoc = await transaction.get(userRef);

    if (!userDoc.exists) {
      transaction.set(userRef, {
        'baseName': initialBaseName,
        'basePhotoUrl': initialBasePhotoUrl,
        'createdAt': FieldValue.serverTimestamp(),
        'lastActiveAt': FieldValue.serverTimestamp(),
        'profileOnboardingCompleted': false,
        'profileOnboardingCompletedAt': null,
        'notificationSettings': kDefaultNotificationSettings,
        'notificationSettingsDefaultsVersion': 3,
      });
    } else {
      final data = userDoc.data();

      final updates = <String, dynamic>{
        'lastActiveAt': FieldValue.serverTimestamp(),
      };

      if (data == null || !data.containsKey('createdAt')) {
        updates['createdAt'] = FieldValue.serverTimestamp();
      }

      if (data == null || data['notificationSettings'] is! Map) {
        updates['notificationSettings'] = kDefaultNotificationSettings;
        updates['notificationSettingsDefaultsVersion'] = 3;
      } else if (data['notificationSettingsDefaultsVersion'] != 3) {
        final rawSettings = data['notificationSettings'];
        final settings = rawSettings is Map ? rawSettings : const {};
        if (settings['newMembersEnabled'] is! bool) {
          updates['notificationSettings.newMembersEnabled'] = true;
        }
        if (settings['weeklySummaryEnabled'] is! bool) {
          updates['notificationSettings.weeklySummaryEnabled'] = false;
        }
        if (settings['soundEnabled'] is! bool) {
          updates['notificationSettings.soundEnabled'] = true;
        }
        if (settings['vibrationEnabled'] is! bool) {
          updates['notificationSettings.vibrationEnabled'] = true;
        }
        if (settings['chatMessagesEnabled'] is! bool) {
          updates['notificationSettings.chatMessagesEnabled'] = false;
        }
        updates['notificationSettingsDefaultsVersion'] = 3;
      }

      transaction.update(userRef, updates);
    }
  });

  try {
    final syncedUserDoc = await userRef.get();
    final syncedData = syncedUserDoc.data();
    final rawName = syncedData?['baseName'];
    final rawPhotoUrl = syncedData?['basePhotoUrl'];
    final effectiveName = rawName is String && rawName.trim().isNotEmpty
        ? rawName.trim()
        : null;
    final effectivePhotoUrl =
        rawPhotoUrl is String && rawPhotoUrl.trim().isNotEmpty
        ? rawPhotoUrl.trim()
        : null;

    await propagarPerfilUsuarioAGrupos(
      uid: user.uid,
      effectiveName: effectiveName,
      effectivePhotoUrl: effectivePhotoUrl,
    );
  } catch (error) {
    logDebug('No se pudo sincronizar el perfil con los grupos: $error');
  }
}

Future<void> actualizarNombreUsuario(User user, String nuevoNombre) async {
  final trimmedName = nuevoNombre.trim();

  if (trimmedName.isEmpty) {
    throw Exception('El nombre no puede estar vacío');
  }

  await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
    'baseName': trimmedName,
    'lastActiveAt': FieldValue.serverTimestamp(),
  }, SetOptions(merge: true));

  try {
    await user.updateDisplayName(trimmedName);
  } catch (error) {
    logDebug('No se pudo actualizar el nombre en Auth: $error');
  }

  try {
    await propagarPerfilUsuarioAGrupos(
      uid: user.uid,
      effectiveName: trimmedName,
    );
  } catch (error) {
    logDebug('No se pudo propagar el nombre a los grupos: $error');
  }
}

Future<void> borrarFotoPerfilAnterior(String? storagePath) async {
  final trimmedPath = storagePath?.trim();
  if (trimmedPath == null || trimmedPath.isEmpty) return;

  try {
    final callable = FirebaseFunctions.instance.httpsCallable(
      'borrarFotoPerfilAnterior',
    );

    await callable.call<void>({'storagePath': trimmedPath});
  } on FirebaseFunctionsException catch (error) {
    throw Exception(error.message ?? 'No se pudo borrar la foto anterior');
  }
}

Future<String> actualizarFotoPerfilUsuario({
  required User user,
  required XFile foto,
  String? previousStoragePath,
}) async {
  if (!esDomingo()) {
    throw Exception('La foto de perfil solo se puede cambiar los domingos');
  }

  await validarFotoSelfie(foto);

  final firestore = FirebaseFirestore.instance;
  final storage = FirebaseStorage.instance;
  final timestamp = DateTime.now().millisecondsSinceEpoch;
  final storagePath = 'users/${user.uid}/profile/base_$timestamp.jpg';
  final storageRef = storage.ref().child(storagePath);

  await storageRef.putFile(
    File(foto.path),
    SettableMetadata(
      contentType: 'image/jpeg',
      customMetadata: {'uid': user.uid, 'kind': 'profilePhoto'},
    ),
  );

  final downloadUrl = await storageRef.getDownloadURL();

  await firestore.collection('users').doc(user.uid).set({
    'basePhotoUrl': downloadUrl,
    'profilePhotoStoragePath': storagePath,
    'profilePhotoUpdatedAt': FieldValue.serverTimestamp(),
    'lastActiveAt': FieldValue.serverTimestamp(),
  }, SetOptions(merge: true));

  try {
    await user.updatePhotoURL(downloadUrl);
  } catch (error) {
    logDebug('No se pudo actualizar la foto en Auth: $error');
  }

  try {
    await propagarPerfilUsuarioAGrupos(
      uid: user.uid,
      effectivePhotoUrl: downloadUrl,
    );
  } catch (error) {
    logDebug('No se pudo propagar la foto a los grupos: $error');
  }

  final oldPath = previousStoragePath?.trim();
  if (oldPath != null && oldPath.isNotEmpty && oldPath != storagePath) {
    await borrarFotoPerfilAnterior(oldPath);
  }

  return downloadUrl;
}

Future<void> reemplazarFotoPerfilConSelfie({
  required User user,
  required String selfieUrl,
}) async {
  final trimmedUrl = selfieUrl.trim();
  if (trimmedUrl.isEmpty) {
    throw Exception('Esta selfie no tiene una imagen disponible');
  }

  final firestore = FirebaseFirestore.instance;
  final userRef = firestore.collection('users').doc(user.uid);
  final userSnapshot = await userRef.get();
  final previousStoragePath = userSnapshot
      .data()?['profilePhotoStoragePath']
      ?.toString()
      .trim();

  await userRef.set({
    'basePhotoUrl': trimmedUrl,
    'profilePhotoStoragePath': FieldValue.delete(),
    'profilePhotoUpdatedAt': FieldValue.serverTimestamp(),
    'lastActiveAt': FieldValue.serverTimestamp(),
  }, SetOptions(merge: true));

  try {
    await user.updatePhotoURL(trimmedUrl);
  } catch (error) {
    logDebug('No se pudo actualizar la foto en Auth: $error');
  }

  try {
    await propagarPerfilUsuarioAGrupos(
      uid: user.uid,
      effectivePhotoUrl: trimmedUrl,
    );
  } catch (error) {
    logDebug('No se pudo propagar la foto a los grupos: $error');
  }

  if (previousStoragePath != null && previousStoragePath.isNotEmpty) {
    await borrarFotoPerfilAnterior(previousStoragePath);
  }
}

Future<void> propagarPerfilUsuarioAGrupos({
  required String uid,
  String? effectiveName,
  String? effectivePhotoUrl,
}) async {
  final trimmedName = effectiveName?.trim();
  final shouldSyncName = trimmedName != null && trimmedName.isNotEmpty;
  final shouldSyncPhoto = effectivePhotoUrl != null;

  if (!shouldSyncName && !shouldSyncPhoto) return;

  final firestore = FirebaseFirestore.instance;
  final userGroupsSnapshot = await firestore
      .collection('users')
      .doc(uid)
      .collection('groups')
      .get();

  if (userGroupsSnapshot.docs.isEmpty) return;

  WriteBatch batch = firestore.batch();
  var batchCount = 0;

  Future<void> commitIfNeeded({bool force = false}) async {
    if (batchCount == 0) return;
    if (!force && batchCount < 450) return;
    await batch.commit();
    batch = firestore.batch();
    batchCount = 0;
  }

  for (final userGroupDoc in userGroupsSnapshot.docs) {
    final data = userGroupDoc.data();
    final groupId = (data['groupId'] ?? userGroupDoc.id).toString();

    if (groupId.trim().isEmpty) continue;

    final memberRef = firestore
        .collection('groups')
        .doc(groupId)
        .collection('members')
        .doc(uid);

    final memberUpdates = <String, dynamic>{};

    if (shouldSyncName) {
      final memberDoc = await memberRef.get();
      if (!memberDoc.exists) continue;

      final groupNameOverride = nonEmptyStringOrNull(
        memberDoc.data()?['groupNameOverride'],
      );
      if (groupNameOverride == null) {
        memberUpdates['effectiveName'] = trimmedName;
      }
    }

    if (shouldSyncPhoto) {
      memberUpdates['effectivePhotoUrl'] = effectivePhotoUrl;
    }

    if (memberUpdates.isEmpty) continue;

    memberUpdates['profileSyncedAt'] = FieldValue.serverTimestamp();

    batch.set(memberRef, memberUpdates, SetOptions(merge: true));
    batchCount += 1;
    await commitIfNeeded();
  }

  await commitIfNeeded(force: true);
}

Future<void> marcarActividadGrupo({required String groupId}) async {
  final firestore = FirebaseFirestore.instance;
  final groupRef = firestore.collection('groups').doc(groupId);
  final membersSnapshot = await groupRef.collection('members').get();

  WriteBatch batch = firestore.batch();
  var batchCount = 0;

  Future<void> commitIfNeeded({bool force = false}) async {
    if (batchCount == 0) return;
    if (!force && batchCount < 430) return;
    await batch.commit();
    batch = firestore.batch();
    batchCount = 0;
  }

  batch.set(groupRef, {
    'lastActivityAt': FieldValue.serverTimestamp(),
  }, SetOptions(merge: true));
  batchCount += 1;

  for (final memberDoc in membersSnapshot.docs) {
    final userGroupRef = firestore
        .collection('users')
        .doc(memberDoc.id)
        .collection('groups')
        .doc(groupId);

    batch.set(userGroupRef, {
      'groupId': groupId,
      'lastActivityAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    batchCount += 1;
    await commitIfNeeded();
  }

  await commitIfNeeded(force: true);
}

Future<void> actualizarPerfilInicialUsuario({
  required User user,
  required String nombre,
  required XFile foto,
}) async {
  final trimmedName = nombre.trim();

  if (trimmedName.isEmpty) {
    throw Exception('El nombre no puede estar vacío');
  }

  await validarFotoSelfie(foto);

  final firestore = FirebaseFirestore.instance;
  final storage = FirebaseStorage.instance;
  final timestamp = DateTime.now().millisecondsSinceEpoch;
  final storagePath = 'users/${user.uid}/profile/base_$timestamp.jpg';
  final storageRef = storage.ref().child(storagePath);

  await storageRef.putFile(
    File(foto.path),
    SettableMetadata(
      contentType: 'image/jpeg',
      customMetadata: {'uid': user.uid, 'kind': 'profilePhoto'},
    ),
  );

  final downloadUrl = await storageRef.getDownloadURL();

  await firestore.collection('users').doc(user.uid).set({
    'baseName': trimmedName,
    'basePhotoUrl': downloadUrl,
    'profilePhotoStoragePath': storagePath,
    'profileOnboardingCompleted': true,
    'profileOnboardingCompletedAt': FieldValue.serverTimestamp(),
    'lastActiveAt': FieldValue.serverTimestamp(),
  }, SetOptions(merge: true));

  try {
    await user.updateDisplayName(trimmedName);
    await user.updatePhotoURL(downloadUrl);
  } catch (error) {
    logDebug('No se pudo actualizar el perfil Auth: $error');
  }
}

bool perfilInicialPendiente(Map<String, dynamic>? userData) {
  if (userData == null) return true;
  return userData['profileOnboardingCompleted'] != true;
}

String obtenerPlatformActual() {
  if (Platform.isIOS) return 'ios';
  if (Platform.isAndroid) return 'android';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isWindows) return 'windows';
  if (Platform.isLinux) return 'linux';
  return 'unknown';
}

String crearNotificationTokenId(String token) {
  return base64Url.encode(utf8.encode(token)).replaceAll('=', '');
}

const Map<String, bool> kDefaultNotificationSettings = {
  'globalEnabled': true,
  'sundayTimeEnabled': true,
  'newSelfiesEnabled': true,
  'friendRemindersEnabled': true,
  'reactionsEnabled': true,
  'newMembersEnabled': true,
  'weeklySummaryEnabled': false,
  'chatMessagesEnabled': false,
  'soundEnabled': true,
  'vibrationEnabled': true,
};

const Set<String> kForegroundLocalNotificationTypes = {
  'friend_reminder',
  'join_request',
  'join_accepted',
  'chat_message',
};

const String kSelfieNotPortraitMessage =
    'La foto debe ser vertical. Haz o elige una foto en vertical.';
const String kSelfieNoFaceMessage =
    'La foto no es selfie. Debes realizar un selfie.';
const String kSelfieValidationFailedMessage =
    'No se pudo comprobar la foto. Inténtalo de nuevo.';
const String kSelfieTooLargeMessage =
    'La foto pesa demasiado. Haz otro selfie e inténtalo de nuevo.';
const int kSelfieUploadMaxBytes = 9 * 1024 * 1024;
const int kSelfieUploadMaxLongEdge = 1920;
const int kSelfieUploadJpegQuality = 88;
const int kSelfieThumbnailMaxLongEdge = 720;
const int kSelfieThumbnailJpegQuality = 82;

final Set<String> _validatedSelfiePhotoPaths = <String>{};

class SelfiePhotoValidationException implements Exception {
  final String message;

  const SelfiePhotoValidationException(this.message);

  @override
  String toString() => message;
}

Map<String, int>? _decodeOrientedImageSize(Uint8List bytes) {
  final decodedImage = image_lib.decodeImage(bytes);
  if (decodedImage == null) return null;

  return <String, int>{
    'width': decodedImage.width,
    'height': decodedImage.height,
  };
}

Uint8List? _createSelfieThumbnailBytes(Uint8List bytes) {
  final decodedImage = image_lib.decodeImage(bytes);
  if (decodedImage == null) return null;

  final orientedImage = image_lib.bakeOrientation(decodedImage);
  final width = orientedImage.width;
  final height = orientedImage.height;
  final longestEdge = math.max(width, height);
  if (width <= 0 || height <= 0 || longestEdge <= 0) return null;

  final image_lib.Image resizedImage;
  if (longestEdge <= kSelfieThumbnailMaxLongEdge) {
    resizedImage = orientedImage;
  } else if (height >= width) {
    resizedImage = image_lib.copyResize(
      orientedImage,
      height: kSelfieThumbnailMaxLongEdge,
      interpolation: image_lib.Interpolation.average,
    );
  } else {
    resizedImage = image_lib.copyResize(
      orientedImage,
      width: kSelfieThumbnailMaxLongEdge,
      interpolation: image_lib.Interpolation.average,
    );
  }

  return Uint8List.fromList(
    image_lib.encodeJpg(resizedImage, quality: kSelfieThumbnailJpegQuality),
  );
}

Uint8List? _createSelfieUploadBytes(Uint8List bytes) {
  final decodedImage = image_lib.decodeImage(bytes);
  if (decodedImage == null) return null;

  final orientedImage = image_lib.bakeOrientation(decodedImage);
  final width = orientedImage.width;
  final height = orientedImage.height;
  final longestEdge = math.max(width, height);
  if (width <= 0 || height <= 0 || longestEdge <= 0) return null;

  image_lib.Image resizedImage = orientedImage;
  if (longestEdge > kSelfieUploadMaxLongEdge) {
    resizedImage = height >= width
        ? image_lib.copyResize(
            orientedImage,
            height: kSelfieUploadMaxLongEdge,
            interpolation: image_lib.Interpolation.average,
          )
        : image_lib.copyResize(
            orientedImage,
            width: kSelfieUploadMaxLongEdge,
            interpolation: image_lib.Interpolation.average,
          );
  }

  Uint8List? smallestBytes;
  for (final quality in const [kSelfieUploadJpegQuality, 82, 76, 70]) {
    final encoded = Uint8List.fromList(
      image_lib.encodeJpg(resizedImage, quality: quality),
    );
    smallestBytes = encoded;
    if (encoded.length <= kSelfieUploadMaxBytes) return encoded;
  }

  if (math.max(resizedImage.width, resizedImage.height) > 1280) {
    resizedImage = resizedImage.height >= resizedImage.width
        ? image_lib.copyResize(
            resizedImage,
            height: 1280,
            interpolation: image_lib.Interpolation.average,
          )
        : image_lib.copyResize(
            resizedImage,
            width: 1280,
            interpolation: image_lib.Interpolation.average,
          );
    smallestBytes = Uint8List.fromList(
      image_lib.encodeJpg(resizedImage, quality: 82),
    );
  }

  return smallestBytes;
}

String _safeTempFilePart(String value) {
  return value
      .replaceAll(RegExp(r'[^A-Za-z0-9_\-]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .trim();
}

Future<File> _prepararArchivoSelfieParaSubidaTemporal({
  required XFile foto,
  required String groupId,
  required String weekKey,
  required String uid,
}) async {
  final originalFile = File(foto.path);
  final originalExists = await originalFile.exists();
  final originalLength = originalExists
      ? await originalFile.length()
      : await foto.length();

  if (originalExists &&
      originalLength > 0 &&
      originalLength <= kSelfieUploadMaxBytes) {
    return originalFile;
  }

  final bytes = await foto.readAsBytes();
  final uploadBytes = await compute<Uint8List, Uint8List?>(
    _createSelfieUploadBytes,
    bytes,
  );

  if (uploadBytes == null || uploadBytes.isEmpty) {
    throw const SelfiePhotoValidationException(kSelfieValidationFailedMessage);
  }

  if (uploadBytes.length > kSelfieUploadMaxBytes) {
    throw const SelfiePhotoValidationException(kSelfieTooLargeMessage);
  }

  final safeGroupId = _safeTempFilePart(groupId);
  final safeWeekKey = _safeTempFilePart(weekKey);
  final safeUid = _safeTempFilePart(uid);
  final timestamp = DateTime.now().microsecondsSinceEpoch;
  final file = File(
    '${Directory.systemTemp.path}/sunday_upload_${safeGroupId}_${safeWeekKey}_${safeUid}_$timestamp.jpg',
  );
  await file.writeAsBytes(uploadBytes, flush: true);
  return file;
}

Future<File?> crearMiniaturaSelfieTemporal({
  required XFile foto,
  required String groupId,
  required String weekKey,
  required String uid,
}) async {
  final bytes = await foto.readAsBytes();
  final thumbnailBytes = await compute<Uint8List, Uint8List?>(
    _createSelfieThumbnailBytes,
    bytes,
  );
  if (thumbnailBytes == null || thumbnailBytes.isEmpty) return null;

  final safeGroupId = _safeTempFilePart(groupId);
  final safeWeekKey = _safeTempFilePart(weekKey);
  final safeUid = _safeTempFilePart(uid);
  final timestamp = DateTime.now().microsecondsSinceEpoch;
  final file = File(
    '${Directory.systemTemp.path}/sunday_thumb_${safeGroupId}_${safeWeekKey}_${safeUid}_$timestamp.jpg',
  );
  await file.writeAsBytes(thumbnailBytes, flush: true);
  return file;
}

Future<void> validarFotoSelfie(XFile foto) async {
  final cacheKey = foto.path.trim();
  if (cacheKey.isNotEmpty && _validatedSelfiePhotoPaths.contains(cacheKey)) {
    return;
  }

  final bytes = await foto.readAsBytes();
  final dimensions = await compute<Uint8List, Map<String, int>?>(
    _decodeOrientedImageSize,
    bytes,
  );

  final width = dimensions?['width'] ?? 0;
  final height = dimensions?['height'] ?? 0;

  if (width <= 0 || height <= 0) {
    throw const SelfiePhotoValidationException(kSelfieValidationFailedMessage);
  }

  if (height <= width) {
    throw const SelfiePhotoValidationException(kSelfieNotPortraitMessage);
  }

  final detector = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.fast,
      enableClassification: false,
      enableContours: false,
      enableLandmarks: false,
      enableTracking: false,
      minFaceSize: 0.08,
    ),
  );

  try {
    final faces = await detector.processImage(
      InputImage.fromFilePath(foto.path),
    );
    if (faces.isEmpty) {
      throw const SelfiePhotoValidationException(kSelfieNoFaceMessage);
    }

    if (cacheKey.isNotEmpty) {
      _validatedSelfiePhotoPaths.add(cacheKey);
    }
  } on SelfiePhotoValidationException {
    rethrow;
  } on MissingPluginException catch (error) {
    logDebug('Detector de caras no disponible: $error');
    throw const SelfiePhotoValidationException(kSelfieValidationFailedMessage);
  } on PlatformException catch (error) {
    logDebug('No se pudo validar la foto con ML Kit: $error');
    throw const SelfiePhotoValidationException(kSelfieValidationFailedMessage);
  } finally {
    await detector.close();
  }
}

Future<bool> validarFotoSelfieParaSubida(
  BuildContext context,
  XFile foto,
) async {
  try {
    await validarFotoSelfie(foto);
    return true;
  } on SelfiePhotoValidationException catch (error) {
    if (context.mounted) showSundaySnack(context, error.message);
    return false;
  } catch (error) {
    logDebug('No se pudo comprobar la foto: $error');
    if (context.mounted) {
      showSundaySnack(context, kSelfieValidationFailedMessage);
    }
    return false;
  }
}

class EmojiReactionSection {
  final String label;
  final String icon;
  final List<String> emojis;

  const EmojiReactionSection({
    required this.label,
    required this.icon,
    required this.emojis,
  });
}

class EmojiReactionChoiceGroup {
  final String key;
  final String displayEmoji;
  final List<String> variants;

  const EmojiReactionChoiceGroup({
    required this.key,
    required this.displayEmoji,
    required this.variants,
  });
}

bool _isEmojiSkinToneModifier(int value) {
  return value >= 0x1F3FB && value <= 0x1F3FF;
}

String emojiReactionGroupKey(String emoji) {
  final cleanEmoji = normalizarEmojiReaccion(emoji);
  if (cleanEmoji.isEmpty) return '';

  final codePoints = cleanEmoji.runes
      .where((value) => !_isEmojiSkinToneModifier(value))
      .toList(growable: false);
  final base = String.fromCharCodes(codePoints);
  return normalizarEmojiReaccion(base).isEmpty ? cleanEmoji : base;
}

List<EmojiReactionChoiceGroup> agruparEmojisReaccion(List<String> emojis) {
  final grouped = <String, List<String>>{};

  for (final emoji in emojis) {
    final cleanEmoji = normalizarEmojiReaccion(emoji);
    if (cleanEmoji.isEmpty) continue;

    final key = emojiReactionGroupKey(cleanEmoji);
    if (key.isEmpty) continue;

    final variants = grouped.putIfAbsent(key, () => []);
    if (!variants.contains(cleanEmoji)) {
      variants.add(cleanEmoji);
    }
  }

  return grouped.entries
      .map((entry) {
        final variants = entry.value;
        final displayEmoji = variants.contains(entry.key)
            ? entry.key
            : variants.first;

        return EmojiReactionChoiceGroup(
          key: entry.key,
          displayEmoji: displayEmoji,
          variants: List.unmodifiable(variants),
        );
      })
      .toList(growable: false);
}

const List<EmojiReactionSection> kSundayReactionEmojiCategorySections = [
  EmojiReactionSection(
    label: 'Favoritos',
    icon: '❤️',
    emojis: [
      '❤️',
      '😂',
      '😍',
      '🔥',
      '👏',
      '🙌',
      '🥰',
      '😎',
      '😊',
      '😄',
      '🥳',
      '🤩',
      '😮',
      '😢',
      '😭',
      '😜',
      '😇',
      '🤗',
      '😋',
      '😆',
      '👍',
      '👎',
      '💪',
      '🙏',
      '🤝',
      '👌',
      '✌️',
      '🫶',
      '💯',
      '✨',
      '⭐',
      '🌟',
      '💫',
      '🌞',
      '🌈',
      '🎉',
      '🎊',
      '🏆',
      '🥇',
      '👑',
      '📸',
      '💅',
      '🤌',
      '🥹',
      '🫠',
      '🫡',
      '🤯',
      '😱',
      '😳',
      '😌',
      '😏',
      '🙃',
      '😉',
      '😘',
      '💖',
      '💘',
      '💙',
      '💚',
      '💜',
      '🖤',
    ],
  ),
  EmojiReactionSection(
    label: 'Caras',
    icon: '😀',
    emojis: [
      '😀',
      '😃',
      '😄',
      '😁',
      '😆',
      '😅',
      '🤣',
      '😂',
      '🙂',
      '🙃',
      '🫠',
      '😉',
      '😊',
      '😇',
      '🥰',
      '😍',
      '🤩',
      '😘',
      '😗',
      '☺️',
      '😚',
      '😙',
      '🥲',
      '😋',
      '😛',
      '😜',
      '🤪',
      '😝',
      '🤑',
      '🤗',
      '🤭',
      '🫢',
      '🫣',
      '🤫',
      '🤔',
      '🫡',
      '🤐',
      '🤨',
      '😐',
      '😑',
      '😶',
      '🫥',
      '😶‍🌫️',
      '😏',
      '😒',
      '🙄',
      '😬',
      '😮‍💨',
      '🤥',
      '🫨',
      '🙂‍↔️',
      '🙂‍↕️',
      '😌',
      '😔',
      '😪',
      '🤤',
      '😴',
      '🫩',
      '😷',
      '🤒',
      '🤕',
      '🤢',
      '🤮',
      '🤧',
      '🥵',
      '🥶',
      '🥴',
      '😵',
      '😵‍💫',
      '🤯',
      '🤠',
      '🥳',
      '🥸',
      '😎',
      '🤓',
      '🧐',
      '😕',
      '🫤',
      '😟',
      '🙁',
      '☹️',
      '😮',
      '😯',
      '😲',
      '😳',
      '🫪',
      '🥺',
      '🥹',
      '😦',
      '😧',
      '😨',
      '😰',
      '😥',
      '😢',
      '😭',
      '😱',
      '😖',
      '😣',
      '😞',
      '😓',
      '😩',
      '😫',
      '🥱',
      '😤',
      '😡',
      '😠',
      '🤬',
      '😈',
      '👿',
      '💀',
      '☠️',
      '💩',
      '🤡',
      '👹',
      '👺',
      '👻',
      '👽',
      '👾',
      '🤖',
      '😺',
      '😸',
      '😹',
      '😻',
      '😼',
      '😽',
      '🙀',
      '😿',
      '😾',
      '🙈',
      '🙉',
      '🙊',
    ],
  ),
  EmojiReactionSection(
    label: 'Personas',
    icon: '👍',
    emojis: [
      '👋',
      '👋🏻',
      '👋🏼',
      '👋🏽',
      '👋🏾',
      '👋🏿',
      '🤚',
      '🤚🏻',
      '🤚🏼',
      '🤚🏽',
      '🤚🏾',
      '🤚🏿',
      '🖐️',
      '🖐🏻',
      '🖐🏼',
      '🖐🏽',
      '🖐🏾',
      '🖐🏿',
      '✋',
      '✋🏻',
      '✋🏼',
      '✋🏽',
      '✋🏾',
      '✋🏿',
      '🖖',
      '🖖🏻',
      '🖖🏼',
      '🖖🏽',
      '🖖🏾',
      '🖖🏿',
      '🫱',
      '🫱🏻',
      '🫱🏼',
      '🫱🏽',
      '🫱🏾',
      '🫱🏿',
      '🫲',
      '🫲🏻',
      '🫲🏼',
      '🫲🏽',
      '🫲🏾',
      '🫲🏿',
      '🫳',
      '🫳🏻',
      '🫳🏼',
      '🫳🏽',
      '🫳🏾',
      '🫳🏿',
      '🫴',
      '🫴🏻',
      '🫴🏼',
      '🫴🏽',
      '🫴🏾',
      '🫴🏿',
      '🫷',
      '🫷🏻',
      '🫷🏼',
      '🫷🏽',
      '🫷🏾',
      '🫷🏿',
      '🫸',
      '🫸🏻',
      '🫸🏼',
      '🫸🏽',
      '🫸🏾',
      '🫸🏿',
      '👌',
      '👌🏻',
      '👌🏼',
      '👌🏽',
      '👌🏾',
      '👌🏿',
      '🤌',
      '🤌🏻',
      '🤌🏼',
      '🤌🏽',
      '🤌🏾',
      '🤌🏿',
      '🤏',
      '🤏🏻',
      '🤏🏼',
      '🤏🏽',
      '🤏🏾',
      '🤏🏿',
      '✌️',
      '✌🏻',
      '✌🏼',
      '✌🏽',
      '✌🏾',
      '✌🏿',
      '🤞',
      '🤞🏻',
      '🤞🏼',
      '🤞🏽',
      '🤞🏾',
      '🤞🏿',
      '🫰',
      '🫰🏻',
      '🫰🏼',
      '🫰🏽',
      '🫰🏾',
      '🫰🏿',
      '🤟',
      '🤟🏻',
      '🤟🏼',
      '🤟🏽',
      '🤟🏾',
      '🤟🏿',
      '🤘',
      '🤘🏻',
      '🤘🏼',
      '🤘🏽',
      '🤘🏾',
      '🤘🏿',
      '🤙',
      '🤙🏻',
      '🤙🏼',
      '🤙🏽',
      '🤙🏾',
      '🤙🏿',
      '👈',
      '👈🏻',
      '👈🏼',
      '👈🏽',
      '👈🏾',
      '👈🏿',
      '👉',
      '👉🏻',
      '👉🏼',
      '👉🏽',
      '👉🏾',
      '👉🏿',
      '👆',
      '👆🏻',
      '👆🏼',
      '👆🏽',
      '👆🏾',
      '👆🏿',
      '🖕',
      '🖕🏻',
      '🖕🏼',
      '🖕🏽',
      '🖕🏾',
      '🖕🏿',
      '👇',
      '👇🏻',
      '👇🏼',
      '👇🏽',
      '👇🏾',
      '👇🏿',
      '☝️',
      '☝🏻',
      '☝🏼',
      '☝🏽',
      '☝🏾',
      '☝🏿',
      '🫵',
      '🫵🏻',
      '🫵🏼',
      '🫵🏽',
      '🫵🏾',
      '🫵🏿',
      '👍',
      '👍🏻',
      '👍🏼',
      '👍🏽',
      '👍🏾',
      '👍🏿',
      '👎',
      '👎🏻',
      '👎🏼',
      '👎🏽',
      '👎🏾',
      '👎🏿',
      '✊',
      '✊🏻',
      '✊🏼',
      '✊🏽',
      '✊🏾',
      '✊🏿',
      '👊',
      '👊🏻',
      '👊🏼',
      '👊🏽',
      '👊🏾',
      '👊🏿',
      '🤛',
      '🤛🏻',
      '🤛🏼',
      '🤛🏽',
      '🤛🏾',
      '🤛🏿',
      '🤜',
      '🤜🏻',
      '🤜🏼',
      '🤜🏽',
      '🤜🏾',
      '🤜🏿',
      '👏',
      '👏🏻',
      '👏🏼',
      '👏🏽',
      '👏🏾',
      '👏🏿',
      '🙌',
      '🙌🏻',
      '🙌🏼',
      '🙌🏽',
      '🙌🏾',
      '🙌🏿',
      '🫶',
      '🫶🏻',
      '🫶🏼',
      '🫶🏽',
      '🫶🏾',
      '🫶🏿',
      '👐',
      '👐🏻',
      '👐🏼',
      '👐🏽',
      '👐🏾',
      '👐🏿',
      '🤲',
      '🤲🏻',
      '🤲🏼',
      '🤲🏽',
      '🤲🏾',
      '🤲🏿',
      '🤝',
      '🤝🏻',
      '🤝🏼',
      '🤝🏽',
      '🤝🏾',
      '🤝🏿',
      '🫱🏻‍🫲🏼',
      '🫱🏻‍🫲🏽',
      '🫱🏻‍🫲🏾',
      '🫱🏻‍🫲🏿',
      '🫱🏼‍🫲🏻',
      '🫱🏼‍🫲🏽',
      '🫱🏼‍🫲🏾',
      '🫱🏼‍🫲🏿',
      '🫱🏽‍🫲🏻',
      '🫱🏽‍🫲🏼',
      '🫱🏽‍🫲🏾',
      '🫱🏽‍🫲🏿',
      '🫱🏾‍🫲🏻',
      '🫱🏾‍🫲🏼',
      '🫱🏾‍🫲🏽',
      '🫱🏾‍🫲🏿',
      '🫱🏿‍🫲🏻',
      '🫱🏿‍🫲🏼',
      '🫱🏿‍🫲🏽',
      '🫱🏿‍🫲🏾',
      '🙏',
      '🙏🏻',
      '🙏🏼',
      '🙏🏽',
      '🙏🏾',
      '🙏🏿',
      '✍️',
      '✍🏻',
      '✍🏼',
      '✍🏽',
      '✍🏾',
      '✍🏿',
      '💅',
      '💅🏻',
      '💅🏼',
      '💅🏽',
      '💅🏾',
      '💅🏿',
      '🤳',
      '🤳🏻',
      '🤳🏼',
      '🤳🏽',
      '🤳🏾',
      '🤳🏿',
      '💪',
      '💪🏻',
      '💪🏼',
      '💪🏽',
      '💪🏾',
      '💪🏿',
      '🦾',
      '🦿',
      '🦵',
      '🦵🏻',
      '🦵🏼',
      '🦵🏽',
      '🦵🏾',
      '🦵🏿',
      '🦶',
      '🦶🏻',
      '🦶🏼',
      '🦶🏽',
      '🦶🏾',
      '🦶🏿',
      '👂',
      '👂🏻',
      '👂🏼',
      '👂🏽',
      '👂🏾',
      '👂🏿',
      '🦻',
      '🦻🏻',
      '🦻🏼',
      '🦻🏽',
      '🦻🏾',
      '🦻🏿',
      '👃',
      '👃🏻',
      '👃🏼',
      '👃🏽',
      '👃🏾',
      '👃🏿',
      '🧠',
      '🫀',
      '🫁',
      '🦷',
      '🦴',
      '👀',
      '👁️',
      '👅',
      '👄',
      '🫦',
      '👶',
      '👶🏻',
      '👶🏼',
      '👶🏽',
      '👶🏾',
      '👶🏿',
      '🧒',
      '🧒🏻',
      '🧒🏼',
      '🧒🏽',
      '🧒🏾',
      '🧒🏿',
      '👦',
      '👦🏻',
      '👦🏼',
      '👦🏽',
      '👦🏾',
      '👦🏿',
      '👧',
      '👧🏻',
      '👧🏼',
      '👧🏽',
      '👧🏾',
      '👧🏿',
      '🧑',
      '🧑🏻',
      '🧑🏼',
      '🧑🏽',
      '🧑🏾',
      '🧑🏿',
      '👱',
      '👱🏻',
      '👱🏼',
      '👱🏽',
      '👱🏾',
      '👱🏿',
      '👨',
      '👨🏻',
      '👨🏼',
      '👨🏽',
      '👨🏾',
      '👨🏿',
      '🧔',
      '🧔🏻',
      '🧔🏼',
      '🧔🏽',
      '🧔🏾',
      '🧔🏿',
      '🧔‍♂️',
      '🧔🏻‍♂️',
      '🧔🏼‍♂️',
      '🧔🏽‍♂️',
      '🧔🏾‍♂️',
      '🧔🏿‍♂️',
      '🧔‍♀️',
      '🧔🏻‍♀️',
      '🧔🏼‍♀️',
      '🧔🏽‍♀️',
      '🧔🏾‍♀️',
      '🧔🏿‍♀️',
      '👨‍🦰',
      '👨🏻‍🦰',
      '👨🏼‍🦰',
      '👨🏽‍🦰',
      '👨🏾‍🦰',
      '👨🏿‍🦰',
      '👨‍🦱',
      '👨🏻‍🦱',
      '👨🏼‍🦱',
      '👨🏽‍🦱',
      '👨🏾‍🦱',
      '👨🏿‍🦱',
      '👨‍🦳',
      '👨🏻‍🦳',
      '👨🏼‍🦳',
      '👨🏽‍🦳',
      '👨🏾‍🦳',
      '👨🏿‍🦳',
      '👨‍🦲',
      '👨🏻‍🦲',
      '👨🏼‍🦲',
      '👨🏽‍🦲',
      '👨🏾‍🦲',
      '👨🏿‍🦲',
      '👩',
      '👩🏻',
      '👩🏼',
      '👩🏽',
      '👩🏾',
      '👩🏿',
      '👩‍🦰',
      '👩🏻‍🦰',
      '👩🏼‍🦰',
      '👩🏽‍🦰',
      '👩🏾‍🦰',
      '👩🏿‍🦰',
      '🧑‍🦰',
      '🧑🏻‍🦰',
      '🧑🏼‍🦰',
      '🧑🏽‍🦰',
      '🧑🏾‍🦰',
      '🧑🏿‍🦰',
      '👩‍🦱',
      '👩🏻‍🦱',
      '👩🏼‍🦱',
      '👩🏽‍🦱',
      '👩🏾‍🦱',
      '👩🏿‍🦱',
      '🧑‍🦱',
      '🧑🏻‍🦱',
      '🧑🏼‍🦱',
      '🧑🏽‍🦱',
      '🧑🏾‍🦱',
      '🧑🏿‍🦱',
      '👩‍🦳',
      '👩🏻‍🦳',
      '👩🏼‍🦳',
      '👩🏽‍🦳',
      '👩🏾‍🦳',
      '👩🏿‍🦳',
      '🧑‍🦳',
      '🧑🏻‍🦳',
      '🧑🏼‍🦳',
      '🧑🏽‍🦳',
      '🧑🏾‍🦳',
      '🧑🏿‍🦳',
      '👩‍🦲',
      '👩🏻‍🦲',
      '👩🏼‍🦲',
      '👩🏽‍🦲',
      '👩🏾‍🦲',
      '👩🏿‍🦲',
      '🧑‍🦲',
      '🧑🏻‍🦲',
      '🧑🏼‍🦲',
      '🧑🏽‍🦲',
      '🧑🏾‍🦲',
      '🧑🏿‍🦲',
      '👱‍♀️',
      '👱🏻‍♀️',
      '👱🏼‍♀️',
      '👱🏽‍♀️',
      '👱🏾‍♀️',
      '👱🏿‍♀️',
      '👱‍♂️',
      '👱🏻‍♂️',
      '👱🏼‍♂️',
      '👱🏽‍♂️',
      '👱🏾‍♂️',
      '👱🏿‍♂️',
      '🧓',
      '🧓🏻',
      '🧓🏼',
      '🧓🏽',
      '🧓🏾',
      '🧓🏿',
      '👴',
      '👴🏻',
      '👴🏼',
      '👴🏽',
      '👴🏾',
      '👴🏿',
      '👵',
      '👵🏻',
      '👵🏼',
      '👵🏽',
      '👵🏾',
      '👵🏿',
      '🙍',
      '🙍🏻',
      '🙍🏼',
      '🙍🏽',
      '🙍🏾',
      '🙍🏿',
      '🙍‍♂️',
      '🙍🏻‍♂️',
      '🙍🏼‍♂️',
      '🙍🏽‍♂️',
      '🙍🏾‍♂️',
      '🙍🏿‍♂️',
      '🙍‍♀️',
      '🙍🏻‍♀️',
      '🙍🏼‍♀️',
      '🙍🏽‍♀️',
      '🙍🏾‍♀️',
      '🙍🏿‍♀️',
      '🙎',
      '🙎🏻',
      '🙎🏼',
      '🙎🏽',
      '🙎🏾',
      '🙎🏿',
      '🙎‍♂️',
      '🙎🏻‍♂️',
      '🙎🏼‍♂️',
      '🙎🏽‍♂️',
      '🙎🏾‍♂️',
      '🙎🏿‍♂️',
      '🙎‍♀️',
      '🙎🏻‍♀️',
      '🙎🏼‍♀️',
      '🙎🏽‍♀️',
      '🙎🏾‍♀️',
      '🙎🏿‍♀️',
      '🙅',
      '🙅🏻',
      '🙅🏼',
      '🙅🏽',
      '🙅🏾',
      '🙅🏿',
      '🙅‍♂️',
      '🙅🏻‍♂️',
      '🙅🏼‍♂️',
      '🙅🏽‍♂️',
      '🙅🏾‍♂️',
      '🙅🏿‍♂️',
      '🙅‍♀️',
      '🙅🏻‍♀️',
      '🙅🏼‍♀️',
      '🙅🏽‍♀️',
      '🙅🏾‍♀️',
      '🙅🏿‍♀️',
      '🙆',
      '🙆🏻',
      '🙆🏼',
      '🙆🏽',
      '🙆🏾',
      '🙆🏿',
      '🙆‍♂️',
      '🙆🏻‍♂️',
      '🙆🏼‍♂️',
      '🙆🏽‍♂️',
      '🙆🏾‍♂️',
      '🙆🏿‍♂️',
      '🙆‍♀️',
      '🙆🏻‍♀️',
      '🙆🏼‍♀️',
      '🙆🏽‍♀️',
      '🙆🏾‍♀️',
      '🙆🏿‍♀️',
      '💁',
      '💁🏻',
      '💁🏼',
      '💁🏽',
      '💁🏾',
      '💁🏿',
      '💁‍♂️',
      '💁🏻‍♂️',
      '💁🏼‍♂️',
      '💁🏽‍♂️',
      '💁🏾‍♂️',
      '💁🏿‍♂️',
      '💁‍♀️',
      '💁🏻‍♀️',
      '💁🏼‍♀️',
      '💁🏽‍♀️',
      '💁🏾‍♀️',
      '💁🏿‍♀️',
      '🙋',
      '🙋🏻',
      '🙋🏼',
      '🙋🏽',
      '🙋🏾',
      '🙋🏿',
      '🙋‍♂️',
      '🙋🏻‍♂️',
      '🙋🏼‍♂️',
      '🙋🏽‍♂️',
      '🙋🏾‍♂️',
      '🙋🏿‍♂️',
      '🙋‍♀️',
      '🙋🏻‍♀️',
      '🙋🏼‍♀️',
      '🙋🏽‍♀️',
      '🙋🏾‍♀️',
      '🙋🏿‍♀️',
      '🧏',
      '🧏🏻',
      '🧏🏼',
      '🧏🏽',
      '🧏🏾',
      '🧏🏿',
      '🧏‍♂️',
      '🧏🏻‍♂️',
      '🧏🏼‍♂️',
      '🧏🏽‍♂️',
      '🧏🏾‍♂️',
      '🧏🏿‍♂️',
      '🧏‍♀️',
      '🧏🏻‍♀️',
      '🧏🏼‍♀️',
      '🧏🏽‍♀️',
      '🧏🏾‍♀️',
      '🧏🏿‍♀️',
      '🙇',
      '🙇🏻',
      '🙇🏼',
      '🙇🏽',
      '🙇🏾',
      '🙇🏿',
      '🙇‍♂️',
      '🙇🏻‍♂️',
      '🙇🏼‍♂️',
      '🙇🏽‍♂️',
      '🙇🏾‍♂️',
      '🙇🏿‍♂️',
      '🙇‍♀️',
      '🙇🏻‍♀️',
      '🙇🏼‍♀️',
      '🙇🏽‍♀️',
      '🙇🏾‍♀️',
      '🙇🏿‍♀️',
      '🤦',
      '🤦🏻',
      '🤦🏼',
      '🤦🏽',
      '🤦🏾',
      '🤦🏿',
      '🤦‍♂️',
      '🤦🏻‍♂️',
      '🤦🏼‍♂️',
      '🤦🏽‍♂️',
      '🤦🏾‍♂️',
      '🤦🏿‍♂️',
      '🤦‍♀️',
      '🤦🏻‍♀️',
      '🤦🏼‍♀️',
      '🤦🏽‍♀️',
      '🤦🏾‍♀️',
      '🤦🏿‍♀️',
      '🤷',
      '🤷🏻',
      '🤷🏼',
      '🤷🏽',
      '🤷🏾',
      '🤷🏿',
      '🤷‍♂️',
      '🤷🏻‍♂️',
      '🤷🏼‍♂️',
      '🤷🏽‍♂️',
      '🤷🏾‍♂️',
      '🤷🏿‍♂️',
      '🤷‍♀️',
      '🤷🏻‍♀️',
      '🤷🏼‍♀️',
      '🤷🏽‍♀️',
      '🤷🏾‍♀️',
      '🤷🏿‍♀️',
      '🧑‍⚕️',
      '🧑🏻‍⚕️',
      '🧑🏼‍⚕️',
      '🧑🏽‍⚕️',
      '🧑🏾‍⚕️',
      '🧑🏿‍⚕️',
      '👨‍⚕️',
      '👨🏻‍⚕️',
      '👨🏼‍⚕️',
      '👨🏽‍⚕️',
      '👨🏾‍⚕️',
      '👨🏿‍⚕️',
      '👩‍⚕️',
      '👩🏻‍⚕️',
      '👩🏼‍⚕️',
      '👩🏽‍⚕️',
      '👩🏾‍⚕️',
      '👩🏿‍⚕️',
      '🧑‍🎓',
      '🧑🏻‍🎓',
      '🧑🏼‍🎓',
      '🧑🏽‍🎓',
      '🧑🏾‍🎓',
      '🧑🏿‍🎓',
      '👨‍🎓',
      '👨🏻‍🎓',
      '👨🏼‍🎓',
      '👨🏽‍🎓',
      '👨🏾‍🎓',
      '👨🏿‍🎓',
      '👩‍🎓',
      '👩🏻‍🎓',
      '👩🏼‍🎓',
      '👩🏽‍🎓',
      '👩🏾‍🎓',
      '👩🏿‍🎓',
      '🧑‍🏫',
      '🧑🏻‍🏫',
      '🧑🏼‍🏫',
      '🧑🏽‍🏫',
      '🧑🏾‍🏫',
      '🧑🏿‍🏫',
      '👨‍🏫',
      '👨🏻‍🏫',
      '👨🏼‍🏫',
      '👨🏽‍🏫',
      '👨🏾‍🏫',
      '👨🏿‍🏫',
      '👩‍🏫',
      '👩🏻‍🏫',
      '👩🏼‍🏫',
      '👩🏽‍🏫',
      '👩🏾‍🏫',
      '👩🏿‍🏫',
      '🧑‍⚖️',
      '🧑🏻‍⚖️',
      '🧑🏼‍⚖️',
      '🧑🏽‍⚖️',
      '🧑🏾‍⚖️',
      '🧑🏿‍⚖️',
      '👨‍⚖️',
      '👨🏻‍⚖️',
      '👨🏼‍⚖️',
      '👨🏽‍⚖️',
      '👨🏾‍⚖️',
      '👨🏿‍⚖️',
      '👩‍⚖️',
      '👩🏻‍⚖️',
      '👩🏼‍⚖️',
      '👩🏽‍⚖️',
      '👩🏾‍⚖️',
      '👩🏿‍⚖️',
      '🧑‍🌾',
      '🧑🏻‍🌾',
      '🧑🏼‍🌾',
      '🧑🏽‍🌾',
      '🧑🏾‍🌾',
      '🧑🏿‍🌾',
      '👨‍🌾',
      '👨🏻‍🌾',
      '👨🏼‍🌾',
      '👨🏽‍🌾',
      '👨🏾‍🌾',
      '👨🏿‍🌾',
      '👩‍🌾',
      '👩🏻‍🌾',
      '👩🏼‍🌾',
      '👩🏽‍🌾',
      '👩🏾‍🌾',
      '👩🏿‍🌾',
      '🧑‍🍳',
      '🧑🏻‍🍳',
      '🧑🏼‍🍳',
      '🧑🏽‍🍳',
      '🧑🏾‍🍳',
      '🧑🏿‍🍳',
      '👨‍🍳',
      '👨🏻‍🍳',
      '👨🏼‍🍳',
      '👨🏽‍🍳',
      '👨🏾‍🍳',
      '👨🏿‍🍳',
      '👩‍🍳',
      '👩🏻‍🍳',
      '👩🏼‍🍳',
      '👩🏽‍🍳',
      '👩🏾‍🍳',
      '👩🏿‍🍳',
      '🧑‍🔧',
      '🧑🏻‍🔧',
      '🧑🏼‍🔧',
      '🧑🏽‍🔧',
      '🧑🏾‍🔧',
      '🧑🏿‍🔧',
      '👨‍🔧',
      '👨🏻‍🔧',
      '👨🏼‍🔧',
      '👨🏽‍🔧',
      '👨🏾‍🔧',
      '👨🏿‍🔧',
      '👩‍🔧',
      '👩🏻‍🔧',
      '👩🏼‍🔧',
      '👩🏽‍🔧',
      '👩🏾‍🔧',
      '👩🏿‍🔧',
      '🧑‍🏭',
      '🧑🏻‍🏭',
      '🧑🏼‍🏭',
      '🧑🏽‍🏭',
      '🧑🏾‍🏭',
      '🧑🏿‍🏭',
      '👨‍🏭',
      '👨🏻‍🏭',
      '👨🏼‍🏭',
      '👨🏽‍🏭',
      '👨🏾‍🏭',
      '👨🏿‍🏭',
      '👩‍🏭',
      '👩🏻‍🏭',
      '👩🏼‍🏭',
      '👩🏽‍🏭',
      '👩🏾‍🏭',
      '👩🏿‍🏭',
      '🧑‍💼',
      '🧑🏻‍💼',
      '🧑🏼‍💼',
      '🧑🏽‍💼',
      '🧑🏾‍💼',
      '🧑🏿‍💼',
      '👨‍💼',
      '👨🏻‍💼',
      '👨🏼‍💼',
      '👨🏽‍💼',
      '👨🏾‍💼',
      '👨🏿‍💼',
      '👩‍💼',
      '👩🏻‍💼',
      '👩🏼‍💼',
      '👩🏽‍💼',
      '👩🏾‍💼',
      '👩🏿‍💼',
      '🧑‍🔬',
      '🧑🏻‍🔬',
      '🧑🏼‍🔬',
      '🧑🏽‍🔬',
      '🧑🏾‍🔬',
      '🧑🏿‍🔬',
      '👨‍🔬',
      '👨🏻‍🔬',
      '👨🏼‍🔬',
      '👨🏽‍🔬',
      '👨🏾‍🔬',
      '👨🏿‍🔬',
      '👩‍🔬',
      '👩🏻‍🔬',
      '👩🏼‍🔬',
      '👩🏽‍🔬',
      '👩🏾‍🔬',
      '👩🏿‍🔬',
      '🧑‍💻',
      '🧑🏻‍💻',
      '🧑🏼‍💻',
      '🧑🏽‍💻',
      '🧑🏾‍💻',
      '🧑🏿‍💻',
      '👨‍💻',
      '👨🏻‍💻',
      '👨🏼‍💻',
      '👨🏽‍💻',
      '👨🏾‍💻',
      '👨🏿‍💻',
      '👩‍💻',
      '👩🏻‍💻',
      '👩🏼‍💻',
      '👩🏽‍💻',
      '👩🏾‍💻',
      '👩🏿‍💻',
      '🧑‍🎤',
      '🧑🏻‍🎤',
      '🧑🏼‍🎤',
      '🧑🏽‍🎤',
      '🧑🏾‍🎤',
      '🧑🏿‍🎤',
      '👨‍🎤',
      '👨🏻‍🎤',
      '👨🏼‍🎤',
      '👨🏽‍🎤',
      '👨🏾‍🎤',
      '👨🏿‍🎤',
      '👩‍🎤',
      '👩🏻‍🎤',
      '👩🏼‍🎤',
      '👩🏽‍🎤',
      '👩🏾‍🎤',
      '👩🏿‍🎤',
      '🧑‍🎨',
      '🧑🏻‍🎨',
      '🧑🏼‍🎨',
      '🧑🏽‍🎨',
      '🧑🏾‍🎨',
      '🧑🏿‍🎨',
      '👨‍🎨',
      '👨🏻‍🎨',
      '👨🏼‍🎨',
      '👨🏽‍🎨',
      '👨🏾‍🎨',
      '👨🏿‍🎨',
      '👩‍🎨',
      '👩🏻‍🎨',
      '👩🏼‍🎨',
      '👩🏽‍🎨',
      '👩🏾‍🎨',
      '👩🏿‍🎨',
      '🧑‍✈️',
      '🧑🏻‍✈️',
      '🧑🏼‍✈️',
      '🧑🏽‍✈️',
      '🧑🏾‍✈️',
      '🧑🏿‍✈️',
      '👨‍✈️',
      '👨🏻‍✈️',
      '👨🏼‍✈️',
      '👨🏽‍✈️',
      '👨🏾‍✈️',
      '👨🏿‍✈️',
      '👩‍✈️',
      '👩🏻‍✈️',
      '👩🏼‍✈️',
      '👩🏽‍✈️',
      '👩🏾‍✈️',
      '👩🏿‍✈️',
      '🧑‍🚀',
      '🧑🏻‍🚀',
      '🧑🏼‍🚀',
      '🧑🏽‍🚀',
      '🧑🏾‍🚀',
      '🧑🏿‍🚀',
      '👨‍🚀',
      '👨🏻‍🚀',
      '👨🏼‍🚀',
      '👨🏽‍🚀',
      '👨🏾‍🚀',
      '👨🏿‍🚀',
      '👩‍🚀',
      '👩🏻‍🚀',
      '👩🏼‍🚀',
      '👩🏽‍🚀',
      '👩🏾‍🚀',
      '👩🏿‍🚀',
      '🧑‍🚒',
      '🧑🏻‍🚒',
      '🧑🏼‍🚒',
      '🧑🏽‍🚒',
      '🧑🏾‍🚒',
      '🧑🏿‍🚒',
      '👨‍🚒',
      '👨🏻‍🚒',
      '👨🏼‍🚒',
      '👨🏽‍🚒',
      '👨🏾‍🚒',
      '👨🏿‍🚒',
      '👩‍🚒',
      '👩🏻‍🚒',
      '👩🏼‍🚒',
      '👩🏽‍🚒',
      '👩🏾‍🚒',
      '👩🏿‍🚒',
      '👮',
      '👮🏻',
      '👮🏼',
      '👮🏽',
      '👮🏾',
      '👮🏿',
      '👮‍♂️',
      '👮🏻‍♂️',
      '👮🏼‍♂️',
      '👮🏽‍♂️',
      '👮🏾‍♂️',
      '👮🏿‍♂️',
      '👮‍♀️',
      '👮🏻‍♀️',
      '👮🏼‍♀️',
      '👮🏽‍♀️',
      '👮🏾‍♀️',
      '👮🏿‍♀️',
      '🕵️',
      '🕵🏻',
      '🕵🏼',
      '🕵🏽',
      '🕵🏾',
      '🕵🏿',
      '🕵️‍♂️',
      '🕵🏻‍♂️',
      '🕵🏼‍♂️',
      '🕵🏽‍♂️',
      '🕵🏾‍♂️',
      '🕵🏿‍♂️',
      '🕵️‍♀️',
      '🕵🏻‍♀️',
      '🕵🏼‍♀️',
      '🕵🏽‍♀️',
      '🕵🏾‍♀️',
      '🕵🏿‍♀️',
      '💂',
      '💂🏻',
      '💂🏼',
      '💂🏽',
      '💂🏾',
      '💂🏿',
      '💂‍♂️',
      '💂🏻‍♂️',
      '💂🏼‍♂️',
      '💂🏽‍♂️',
      '💂🏾‍♂️',
      '💂🏿‍♂️',
      '💂‍♀️',
      '💂🏻‍♀️',
      '💂🏼‍♀️',
      '💂🏽‍♀️',
      '💂🏾‍♀️',
      '💂🏿‍♀️',
      '🥷',
      '🥷🏻',
      '🥷🏼',
      '🥷🏽',
      '🥷🏾',
      '🥷🏿',
      '👷',
      '👷🏻',
      '👷🏼',
      '👷🏽',
      '👷🏾',
      '👷🏿',
      '👷‍♂️',
      '👷🏻‍♂️',
      '👷🏼‍♂️',
      '👷🏽‍♂️',
      '👷🏾‍♂️',
      '👷🏿‍♂️',
      '👷‍♀️',
      '👷🏻‍♀️',
      '👷🏼‍♀️',
      '👷🏽‍♀️',
      '👷🏾‍♀️',
      '👷🏿‍♀️',
      '🫅',
      '🫅🏻',
      '🫅🏼',
      '🫅🏽',
      '🫅🏾',
      '🫅🏿',
      '🤴',
      '🤴🏻',
      '🤴🏼',
      '🤴🏽',
      '🤴🏾',
      '🤴🏿',
      '👸',
      '👸🏻',
      '👸🏼',
      '👸🏽',
      '👸🏾',
      '👸🏿',
      '👳',
      '👳🏻',
      '👳🏼',
      '👳🏽',
      '👳🏾',
      '👳🏿',
      '👳‍♂️',
      '👳🏻‍♂️',
      '👳🏼‍♂️',
      '👳🏽‍♂️',
      '👳🏾‍♂️',
      '👳🏿‍♂️',
      '👳‍♀️',
      '👳🏻‍♀️',
      '👳🏼‍♀️',
      '👳🏽‍♀️',
      '👳🏾‍♀️',
      '👳🏿‍♀️',
      '👲',
      '👲🏻',
      '👲🏼',
      '👲🏽',
      '👲🏾',
      '👲🏿',
      '🧕',
      '🧕🏻',
      '🧕🏼',
      '🧕🏽',
      '🧕🏾',
      '🧕🏿',
      '🤵',
      '🤵🏻',
      '🤵🏼',
      '🤵🏽',
      '🤵🏾',
      '🤵🏿',
      '🤵‍♂️',
      '🤵🏻‍♂️',
      '🤵🏼‍♂️',
      '🤵🏽‍♂️',
      '🤵🏾‍♂️',
      '🤵🏿‍♂️',
      '🤵‍♀️',
      '🤵🏻‍♀️',
      '🤵🏼‍♀️',
      '🤵🏽‍♀️',
      '🤵🏾‍♀️',
      '🤵🏿‍♀️',
      '👰',
      '👰🏻',
      '👰🏼',
      '👰🏽',
      '👰🏾',
      '👰🏿',
      '👰‍♂️',
      '👰🏻‍♂️',
      '👰🏼‍♂️',
      '👰🏽‍♂️',
      '👰🏾‍♂️',
      '👰🏿‍♂️',
      '👰‍♀️',
      '👰🏻‍♀️',
      '👰🏼‍♀️',
      '👰🏽‍♀️',
      '👰🏾‍♀️',
      '👰🏿‍♀️',
      '🤰',
      '🤰🏻',
      '🤰🏼',
      '🤰🏽',
      '🤰🏾',
      '🤰🏿',
      '🫃',
      '🫃🏻',
      '🫃🏼',
      '🫃🏽',
      '🫃🏾',
      '🫃🏿',
      '🫄',
      '🫄🏻',
      '🫄🏼',
      '🫄🏽',
      '🫄🏾',
      '🫄🏿',
      '🤱',
      '🤱🏻',
      '🤱🏼',
      '🤱🏽',
      '🤱🏾',
      '🤱🏿',
      '👩‍🍼',
      '👩🏻‍🍼',
      '👩🏼‍🍼',
      '👩🏽‍🍼',
      '👩🏾‍🍼',
      '👩🏿‍🍼',
      '👨‍🍼',
      '👨🏻‍🍼',
      '👨🏼‍🍼',
      '👨🏽‍🍼',
      '👨🏾‍🍼',
      '👨🏿‍🍼',
      '🧑‍🍼',
      '🧑🏻‍🍼',
      '🧑🏼‍🍼',
      '🧑🏽‍🍼',
      '🧑🏾‍🍼',
      '🧑🏿‍🍼',
      '👼',
      '👼🏻',
      '👼🏼',
      '👼🏽',
      '👼🏾',
      '👼🏿',
      '🎅',
      '🎅🏻',
      '🎅🏼',
      '🎅🏽',
      '🎅🏾',
      '🎅🏿',
      '🤶',
      '🤶🏻',
      '🤶🏼',
      '🤶🏽',
      '🤶🏾',
      '🤶🏿',
      '🧑‍🎄',
      '🧑🏻‍🎄',
      '🧑🏼‍🎄',
      '🧑🏽‍🎄',
      '🧑🏾‍🎄',
      '🧑🏿‍🎄',
      '🦸',
      '🦸🏻',
      '🦸🏼',
      '🦸🏽',
      '🦸🏾',
      '🦸🏿',
      '🦸‍♂️',
      '🦸🏻‍♂️',
      '🦸🏼‍♂️',
      '🦸🏽‍♂️',
      '🦸🏾‍♂️',
      '🦸🏿‍♂️',
      '🦸‍♀️',
      '🦸🏻‍♀️',
      '🦸🏼‍♀️',
      '🦸🏽‍♀️',
      '🦸🏾‍♀️',
      '🦸🏿‍♀️',
      '🦹',
      '🦹🏻',
      '🦹🏼',
      '🦹🏽',
      '🦹🏾',
      '🦹🏿',
      '🦹‍♂️',
      '🦹🏻‍♂️',
      '🦹🏼‍♂️',
      '🦹🏽‍♂️',
      '🦹🏾‍♂️',
      '🦹🏿‍♂️',
      '🦹‍♀️',
      '🦹🏻‍♀️',
      '🦹🏼‍♀️',
      '🦹🏽‍♀️',
      '🦹🏾‍♀️',
      '🦹🏿‍♀️',
      '🧙',
      '🧙🏻',
      '🧙🏼',
      '🧙🏽',
      '🧙🏾',
      '🧙🏿',
      '🧙‍♂️',
      '🧙🏻‍♂️',
      '🧙🏼‍♂️',
      '🧙🏽‍♂️',
      '🧙🏾‍♂️',
      '🧙🏿‍♂️',
      '🧙‍♀️',
      '🧙🏻‍♀️',
      '🧙🏼‍♀️',
      '🧙🏽‍♀️',
      '🧙🏾‍♀️',
      '🧙🏿‍♀️',
      '🧚',
      '🧚🏻',
      '🧚🏼',
      '🧚🏽',
      '🧚🏾',
      '🧚🏿',
      '🧚‍♂️',
      '🧚🏻‍♂️',
      '🧚🏼‍♂️',
      '🧚🏽‍♂️',
      '🧚🏾‍♂️',
      '🧚🏿‍♂️',
      '🧚‍♀️',
      '🧚🏻‍♀️',
      '🧚🏼‍♀️',
      '🧚🏽‍♀️',
      '🧚🏾‍♀️',
      '🧚🏿‍♀️',
      '🧛',
      '🧛🏻',
      '🧛🏼',
      '🧛🏽',
      '🧛🏾',
      '🧛🏿',
      '🧛‍♂️',
      '🧛🏻‍♂️',
      '🧛🏼‍♂️',
      '🧛🏽‍♂️',
      '🧛🏾‍♂️',
      '🧛🏿‍♂️',
      '🧛‍♀️',
      '🧛🏻‍♀️',
      '🧛🏼‍♀️',
      '🧛🏽‍♀️',
      '🧛🏾‍♀️',
      '🧛🏿‍♀️',
      '🧜',
      '🧜🏻',
      '🧜🏼',
      '🧜🏽',
      '🧜🏾',
      '🧜🏿',
      '🧜‍♂️',
      '🧜🏻‍♂️',
      '🧜🏼‍♂️',
      '🧜🏽‍♂️',
      '🧜🏾‍♂️',
      '🧜🏿‍♂️',
      '🧜‍♀️',
      '🧜🏻‍♀️',
      '🧜🏼‍♀️',
      '🧜🏽‍♀️',
      '🧜🏾‍♀️',
      '🧜🏿‍♀️',
      '🧝',
      '🧝🏻',
      '🧝🏼',
      '🧝🏽',
      '🧝🏾',
      '🧝🏿',
      '🧝‍♂️',
      '🧝🏻‍♂️',
      '🧝🏼‍♂️',
      '🧝🏽‍♂️',
      '🧝🏾‍♂️',
      '🧝🏿‍♂️',
      '🧝‍♀️',
      '🧝🏻‍♀️',
      '🧝🏼‍♀️',
      '🧝🏽‍♀️',
      '🧝🏾‍♀️',
      '🧝🏿‍♀️',
      '🧞',
      '🧞‍♂️',
      '🧞‍♀️',
      '🧟',
      '🧟‍♂️',
      '🧟‍♀️',
      '🧌',
      '🫈',
      '💆',
      '💆🏻',
      '💆🏼',
      '💆🏽',
      '💆🏾',
      '💆🏿',
      '💆‍♂️',
      '💆🏻‍♂️',
      '💆🏼‍♂️',
      '💆🏽‍♂️',
      '💆🏾‍♂️',
      '💆🏿‍♂️',
      '💆‍♀️',
      '💆🏻‍♀️',
      '💆🏼‍♀️',
      '💆🏽‍♀️',
      '💆🏾‍♀️',
      '💆🏿‍♀️',
      '💇',
      '💇🏻',
      '💇🏼',
      '💇🏽',
      '💇🏾',
      '💇🏿',
      '💇‍♂️',
      '💇🏻‍♂️',
      '💇🏼‍♂️',
      '💇🏽‍♂️',
      '💇🏾‍♂️',
      '💇🏿‍♂️',
      '💇‍♀️',
      '💇🏻‍♀️',
      '💇🏼‍♀️',
      '💇🏽‍♀️',
      '💇🏾‍♀️',
      '💇🏿‍♀️',
      '🚶',
      '🚶🏻',
      '🚶🏼',
      '🚶🏽',
      '🚶🏾',
      '🚶🏿',
      '🚶‍♂️',
      '🚶🏻‍♂️',
      '🚶🏼‍♂️',
      '🚶🏽‍♂️',
      '🚶🏾‍♂️',
      '🚶🏿‍♂️',
      '🚶‍♀️',
      '🚶🏻‍♀️',
      '🚶🏼‍♀️',
      '🚶🏽‍♀️',
      '🚶🏾‍♀️',
      '🚶🏿‍♀️',
      '🚶‍➡️',
      '🚶🏻‍➡️',
      '🚶🏼‍➡️',
      '🚶🏽‍➡️',
      '🚶🏾‍➡️',
      '🚶🏿‍➡️',
      '🚶‍♀️‍➡️',
      '🚶🏻‍♀️‍➡️',
      '🚶🏼‍♀️‍➡️',
      '🚶🏽‍♀️‍➡️',
      '🚶🏾‍♀️‍➡️',
      '🚶🏿‍♀️‍➡️',
      '🚶‍♂️‍➡️',
      '🚶🏻‍♂️‍➡️',
      '🚶🏼‍♂️‍➡️',
      '🚶🏽‍♂️‍➡️',
      '🚶🏾‍♂️‍➡️',
      '🚶🏿‍♂️‍➡️',
      '🧍',
      '🧍🏻',
      '🧍🏼',
      '🧍🏽',
      '🧍🏾',
      '🧍🏿',
      '🧍‍♂️',
      '🧍🏻‍♂️',
      '🧍🏼‍♂️',
      '🧍🏽‍♂️',
      '🧍🏾‍♂️',
      '🧍🏿‍♂️',
      '🧍‍♀️',
      '🧍🏻‍♀️',
      '🧍🏼‍♀️',
      '🧍🏽‍♀️',
      '🧍🏾‍♀️',
      '🧍🏿‍♀️',
      '🧎',
      '🧎🏻',
      '🧎🏼',
      '🧎🏽',
      '🧎🏾',
      '🧎🏿',
      '🧎‍♂️',
      '🧎🏻‍♂️',
      '🧎🏼‍♂️',
      '🧎🏽‍♂️',
      '🧎🏾‍♂️',
      '🧎🏿‍♂️',
      '🧎‍♀️',
      '🧎🏻‍♀️',
      '🧎🏼‍♀️',
      '🧎🏽‍♀️',
      '🧎🏾‍♀️',
      '🧎🏿‍♀️',
      '🧎‍➡️',
      '🧎🏻‍➡️',
      '🧎🏼‍➡️',
      '🧎🏽‍➡️',
      '🧎🏾‍➡️',
      '🧎🏿‍➡️',
      '🧎‍♀️‍➡️',
      '🧎🏻‍♀️‍➡️',
      '🧎🏼‍♀️‍➡️',
      '🧎🏽‍♀️‍➡️',
      '🧎🏾‍♀️‍➡️',
      '🧎🏿‍♀️‍➡️',
      '🧎‍♂️‍➡️',
      '🧎🏻‍♂️‍➡️',
      '🧎🏼‍♂️‍➡️',
      '🧎🏽‍♂️‍➡️',
      '🧎🏾‍♂️‍➡️',
      '🧎🏿‍♂️‍➡️',
      '🧑‍🦯',
      '🧑🏻‍🦯',
      '🧑🏼‍🦯',
      '🧑🏽‍🦯',
      '🧑🏾‍🦯',
      '🧑🏿‍🦯',
      '🧑‍🦯‍➡️',
      '🧑🏻‍🦯‍➡️',
      '🧑🏼‍🦯‍➡️',
      '🧑🏽‍🦯‍➡️',
      '🧑🏾‍🦯‍➡️',
      '🧑🏿‍🦯‍➡️',
      '👨‍🦯',
      '👨🏻‍🦯',
      '👨🏼‍🦯',
      '👨🏽‍🦯',
      '👨🏾‍🦯',
      '👨🏿‍🦯',
      '👨‍🦯‍➡️',
      '👨🏻‍🦯‍➡️',
      '👨🏼‍🦯‍➡️',
      '👨🏽‍🦯‍➡️',
      '👨🏾‍🦯‍➡️',
      '👨🏿‍🦯‍➡️',
      '👩‍🦯',
      '👩🏻‍🦯',
      '👩🏼‍🦯',
      '👩🏽‍🦯',
      '👩🏾‍🦯',
      '👩🏿‍🦯',
      '👩‍🦯‍➡️',
      '👩🏻‍🦯‍➡️',
      '👩🏼‍🦯‍➡️',
      '👩🏽‍🦯‍➡️',
      '👩🏾‍🦯‍➡️',
      '👩🏿‍🦯‍➡️',
      '🧑‍🦼',
      '🧑🏻‍🦼',
      '🧑🏼‍🦼',
      '🧑🏽‍🦼',
      '🧑🏾‍🦼',
      '🧑🏿‍🦼',
      '🧑‍🦼‍➡️',
      '🧑🏻‍🦼‍➡️',
      '🧑🏼‍🦼‍➡️',
      '🧑🏽‍🦼‍➡️',
      '🧑🏾‍🦼‍➡️',
      '🧑🏿‍🦼‍➡️',
      '👨‍🦼',
      '👨🏻‍🦼',
      '👨🏼‍🦼',
      '👨🏽‍🦼',
      '👨🏾‍🦼',
      '👨🏿‍🦼',
      '👨‍🦼‍➡️',
      '👨🏻‍🦼‍➡️',
      '👨🏼‍🦼‍➡️',
      '👨🏽‍🦼‍➡️',
      '👨🏾‍🦼‍➡️',
      '👨🏿‍🦼‍➡️',
      '👩‍🦼',
      '👩🏻‍🦼',
      '👩🏼‍🦼',
      '👩🏽‍🦼',
      '👩🏾‍🦼',
      '👩🏿‍🦼',
      '👩‍🦼‍➡️',
      '👩🏻‍🦼‍➡️',
      '👩🏼‍🦼‍➡️',
      '👩🏽‍🦼‍➡️',
      '👩🏾‍🦼‍➡️',
      '👩🏿‍🦼‍➡️',
      '🧑‍🦽',
      '🧑🏻‍🦽',
      '🧑🏼‍🦽',
      '🧑🏽‍🦽',
      '🧑🏾‍🦽',
      '🧑🏿‍🦽',
      '🧑‍🦽‍➡️',
      '🧑🏻‍🦽‍➡️',
      '🧑🏼‍🦽‍➡️',
      '🧑🏽‍🦽‍➡️',
      '🧑🏾‍🦽‍➡️',
      '🧑🏿‍🦽‍➡️',
      '👨‍🦽',
      '👨🏻‍🦽',
      '👨🏼‍🦽',
      '👨🏽‍🦽',
      '👨🏾‍🦽',
      '👨🏿‍🦽',
      '👨‍🦽‍➡️',
      '👨🏻‍🦽‍➡️',
      '👨🏼‍🦽‍➡️',
      '👨🏽‍🦽‍➡️',
      '👨🏾‍🦽‍➡️',
      '👨🏿‍🦽‍➡️',
      '👩‍🦽',
      '👩🏻‍🦽',
      '👩🏼‍🦽',
      '👩🏽‍🦽',
      '👩🏾‍🦽',
      '👩🏿‍🦽',
      '👩‍🦽‍➡️',
      '👩🏻‍🦽‍➡️',
      '👩🏼‍🦽‍➡️',
      '👩🏽‍🦽‍➡️',
      '👩🏾‍🦽‍➡️',
      '👩🏿‍🦽‍➡️',
      '🏃',
      '🏃🏻',
      '🏃🏼',
      '🏃🏽',
      '🏃🏾',
      '🏃🏿',
      '🏃‍♂️',
      '🏃🏻‍♂️',
      '🏃🏼‍♂️',
      '🏃🏽‍♂️',
      '🏃🏾‍♂️',
      '🏃🏿‍♂️',
      '🏃‍♀️',
      '🏃🏻‍♀️',
      '🏃🏼‍♀️',
      '🏃🏽‍♀️',
      '🏃🏾‍♀️',
      '🏃🏿‍♀️',
      '🏃‍➡️',
      '🏃🏻‍➡️',
      '🏃🏼‍➡️',
      '🏃🏽‍➡️',
      '🏃🏾‍➡️',
      '🏃🏿‍➡️',
      '🏃‍♀️‍➡️',
      '🏃🏻‍♀️‍➡️',
      '🏃🏼‍♀️‍➡️',
      '🏃🏽‍♀️‍➡️',
      '🏃🏾‍♀️‍➡️',
      '🏃🏿‍♀️‍➡️',
      '🏃‍♂️‍➡️',
      '🏃🏻‍♂️‍➡️',
      '🏃🏼‍♂️‍➡️',
      '🏃🏽‍♂️‍➡️',
      '🏃🏾‍♂️‍➡️',
      '🏃🏿‍♂️‍➡️',
      '🧑‍🩰',
      '🧑🏻‍🩰',
      '🧑🏼‍🩰',
      '🧑🏽‍🩰',
      '🧑🏾‍🩰',
      '🧑🏿‍🩰',
      '💃',
      '💃🏻',
      '💃🏼',
      '💃🏽',
      '💃🏾',
      '💃🏿',
      '🕺',
      '🕺🏻',
      '🕺🏼',
      '🕺🏽',
      '🕺🏾',
      '🕺🏿',
      '🕴️',
      '🕴🏻',
      '🕴🏼',
      '🕴🏽',
      '🕴🏾',
      '🕴🏿',
      '👯',
      '👯🏻',
      '👯🏼',
      '👯🏽',
      '👯🏾',
      '👯🏿',
      '👯‍♂️',
      '👯🏻‍♂️',
      '👯🏼‍♂️',
      '👯🏽‍♂️',
      '👯🏾‍♂️',
      '👯🏿‍♂️',
      '👯‍♀️',
      '👯🏻‍♀️',
      '👯🏼‍♀️',
      '👯🏽‍♀️',
      '👯🏾‍♀️',
      '👯🏿‍♀️',
      '🧑🏻‍🐰‍🧑🏼',
      '🧑🏻‍🐰‍🧑🏽',
      '🧑🏻‍🐰‍🧑🏾',
      '🧑🏻‍🐰‍🧑🏿',
      '🧑🏼‍🐰‍🧑🏻',
      '🧑🏼‍🐰‍🧑🏽',
      '🧑🏼‍🐰‍🧑🏾',
      '🧑🏼‍🐰‍🧑🏿',
      '🧑🏽‍🐰‍🧑🏻',
      '🧑🏽‍🐰‍🧑🏼',
      '🧑🏽‍🐰‍🧑🏾',
      '🧑🏽‍🐰‍🧑🏿',
      '🧑🏾‍🐰‍🧑🏻',
      '🧑🏾‍🐰‍🧑🏼',
      '🧑🏾‍🐰‍🧑🏽',
      '🧑🏾‍🐰‍🧑🏿',
      '🧑🏿‍🐰‍🧑🏻',
      '🧑🏿‍🐰‍🧑🏼',
      '🧑🏿‍🐰‍🧑🏽',
      '🧑🏿‍🐰‍🧑🏾',
      '👨🏻‍🐰‍👨🏼',
      '👨🏻‍🐰‍👨🏽',
      '👨🏻‍🐰‍👨🏾',
      '👨🏻‍🐰‍👨🏿',
      '👨🏼‍🐰‍👨🏻',
      '👨🏼‍🐰‍👨🏽',
      '👨🏼‍🐰‍👨🏾',
      '👨🏼‍🐰‍👨🏿',
      '👨🏽‍🐰‍👨🏻',
      '👨🏽‍🐰‍👨🏼',
      '👨🏽‍🐰‍👨🏾',
      '👨🏽‍🐰‍👨🏿',
      '👨🏾‍🐰‍👨🏻',
      '👨🏾‍🐰‍👨🏼',
      '👨🏾‍🐰‍👨🏽',
      '👨🏾‍🐰‍👨🏿',
      '👨🏿‍🐰‍👨🏻',
      '👨🏿‍🐰‍👨🏼',
      '👨🏿‍🐰‍👨🏽',
      '👨🏿‍🐰‍👨🏾',
      '👩🏻‍🐰‍👩🏼',
      '👩🏻‍🐰‍👩🏽',
      '👩🏻‍🐰‍👩🏾',
      '👩🏻‍🐰‍👩🏿',
      '👩🏼‍🐰‍👩🏻',
      '👩🏼‍🐰‍👩🏽',
      '👩🏼‍🐰‍👩🏾',
      '👩🏼‍🐰‍👩🏿',
      '👩🏽‍🐰‍👩🏻',
      '👩🏽‍🐰‍👩🏼',
      '👩🏽‍🐰‍👩🏾',
      '👩🏽‍🐰‍👩🏿',
      '👩🏾‍🐰‍👩🏻',
      '👩🏾‍🐰‍👩🏼',
      '👩🏾‍🐰‍👩🏽',
      '👩🏾‍🐰‍👩🏿',
      '👩🏿‍🐰‍👩🏻',
      '👩🏿‍🐰‍👩🏼',
      '👩🏿‍🐰‍👩🏽',
      '👩🏿‍🐰‍👩🏾',
      '🧖',
      '🧖🏻',
      '🧖🏼',
      '🧖🏽',
      '🧖🏾',
      '🧖🏿',
      '🧖‍♂️',
      '🧖🏻‍♂️',
      '🧖🏼‍♂️',
      '🧖🏽‍♂️',
      '🧖🏾‍♂️',
      '🧖🏿‍♂️',
      '🧖‍♀️',
      '🧖🏻‍♀️',
      '🧖🏼‍♀️',
      '🧖🏽‍♀️',
      '🧖🏾‍♀️',
      '🧖🏿‍♀️',
      '🧗',
      '🧗🏻',
      '🧗🏼',
      '🧗🏽',
      '🧗🏾',
      '🧗🏿',
      '🧗‍♂️',
      '🧗🏻‍♂️',
      '🧗🏼‍♂️',
      '🧗🏽‍♂️',
      '🧗🏾‍♂️',
      '🧗🏿‍♂️',
      '🧗‍♀️',
      '🧗🏻‍♀️',
      '🧗🏼‍♀️',
      '🧗🏽‍♀️',
      '🧗🏾‍♀️',
      '🧗🏿‍♀️',
      '🤺',
      '🏇',
      '🏇🏻',
      '🏇🏼',
      '🏇🏽',
      '🏇🏾',
      '🏇🏿',
      '⛷️',
      '🏂',
      '🏂🏻',
      '🏂🏼',
      '🏂🏽',
      '🏂🏾',
      '🏂🏿',
      '🏌️',
      '🏌🏻',
      '🏌🏼',
      '🏌🏽',
      '🏌🏾',
      '🏌🏿',
      '🏌️‍♂️',
      '🏌🏻‍♂️',
      '🏌🏼‍♂️',
      '🏌🏽‍♂️',
      '🏌🏾‍♂️',
      '🏌🏿‍♂️',
      '🏌️‍♀️',
      '🏌🏻‍♀️',
      '🏌🏼‍♀️',
      '🏌🏽‍♀️',
      '🏌🏾‍♀️',
      '🏌🏿‍♀️',
      '🏄',
      '🏄🏻',
      '🏄🏼',
      '🏄🏽',
      '🏄🏾',
      '🏄🏿',
      '🏄‍♂️',
      '🏄🏻‍♂️',
      '🏄🏼‍♂️',
      '🏄🏽‍♂️',
      '🏄🏾‍♂️',
      '🏄🏿‍♂️',
      '🏄‍♀️',
      '🏄🏻‍♀️',
      '🏄🏼‍♀️',
      '🏄🏽‍♀️',
      '🏄🏾‍♀️',
      '🏄🏿‍♀️',
      '🚣',
      '🚣🏻',
      '🚣🏼',
      '🚣🏽',
      '🚣🏾',
      '🚣🏿',
      '🚣‍♂️',
      '🚣🏻‍♂️',
      '🚣🏼‍♂️',
      '🚣🏽‍♂️',
      '🚣🏾‍♂️',
      '🚣🏿‍♂️',
      '🚣‍♀️',
      '🚣🏻‍♀️',
      '🚣🏼‍♀️',
      '🚣🏽‍♀️',
      '🚣🏾‍♀️',
      '🚣🏿‍♀️',
      '🏊',
      '🏊🏻',
      '🏊🏼',
      '🏊🏽',
      '🏊🏾',
      '🏊🏿',
      '🏊‍♂️',
      '🏊🏻‍♂️',
      '🏊🏼‍♂️',
      '🏊🏽‍♂️',
      '🏊🏾‍♂️',
      '🏊🏿‍♂️',
      '🏊‍♀️',
      '🏊🏻‍♀️',
      '🏊🏼‍♀️',
      '🏊🏽‍♀️',
      '🏊🏾‍♀️',
      '🏊🏿‍♀️',
      '⛹️',
      '⛹🏻',
      '⛹🏼',
      '⛹🏽',
      '⛹🏾',
      '⛹🏿',
      '⛹️‍♂️',
      '⛹🏻‍♂️',
      '⛹🏼‍♂️',
      '⛹🏽‍♂️',
      '⛹🏾‍♂️',
      '⛹🏿‍♂️',
      '⛹️‍♀️',
      '⛹🏻‍♀️',
      '⛹🏼‍♀️',
      '⛹🏽‍♀️',
      '⛹🏾‍♀️',
      '⛹🏿‍♀️',
      '🏋️',
      '🏋🏻',
      '🏋🏼',
      '🏋🏽',
      '🏋🏾',
      '🏋🏿',
      '🏋️‍♂️',
      '🏋🏻‍♂️',
      '🏋🏼‍♂️',
      '🏋🏽‍♂️',
      '🏋🏾‍♂️',
      '🏋🏿‍♂️',
      '🏋️‍♀️',
      '🏋🏻‍♀️',
      '🏋🏼‍♀️',
      '🏋🏽‍♀️',
      '🏋🏾‍♀️',
      '🏋🏿‍♀️',
      '🚴',
      '🚴🏻',
      '🚴🏼',
      '🚴🏽',
      '🚴🏾',
      '🚴🏿',
      '🚴‍♂️',
      '🚴🏻‍♂️',
      '🚴🏼‍♂️',
      '🚴🏽‍♂️',
      '🚴🏾‍♂️',
      '🚴🏿‍♂️',
      '🚴‍♀️',
      '🚴🏻‍♀️',
      '🚴🏼‍♀️',
      '🚴🏽‍♀️',
      '🚴🏾‍♀️',
      '🚴🏿‍♀️',
      '🚵',
      '🚵🏻',
      '🚵🏼',
      '🚵🏽',
      '🚵🏾',
      '🚵🏿',
      '🚵‍♂️',
      '🚵🏻‍♂️',
      '🚵🏼‍♂️',
      '🚵🏽‍♂️',
      '🚵🏾‍♂️',
      '🚵🏿‍♂️',
      '🚵‍♀️',
      '🚵🏻‍♀️',
      '🚵🏼‍♀️',
      '🚵🏽‍♀️',
      '🚵🏾‍♀️',
      '🚵🏿‍♀️',
      '🤸',
      '🤸🏻',
      '🤸🏼',
      '🤸🏽',
      '🤸🏾',
      '🤸🏿',
      '🤸‍♂️',
      '🤸🏻‍♂️',
      '🤸🏼‍♂️',
      '🤸🏽‍♂️',
      '🤸🏾‍♂️',
      '🤸🏿‍♂️',
      '🤸‍♀️',
      '🤸🏻‍♀️',
      '🤸🏼‍♀️',
      '🤸🏽‍♀️',
      '🤸🏾‍♀️',
      '🤸🏿‍♀️',
      '🤼',
      '🤼🏻',
      '🤼🏼',
      '🤼🏽',
      '🤼🏾',
      '🤼🏿',
      '🤼‍♂️',
      '🤼🏻‍♂️',
      '🤼🏼‍♂️',
      '🤼🏽‍♂️',
      '🤼🏾‍♂️',
      '🤼🏿‍♂️',
      '🤼‍♀️',
      '🤼🏻‍♀️',
      '🤼🏼‍♀️',
      '🤼🏽‍♀️',
      '🤼🏾‍♀️',
      '🤼🏿‍♀️',
      '🧑🏻‍🫯‍🧑🏼',
      '🧑🏻‍🫯‍🧑🏽',
      '🧑🏻‍🫯‍🧑🏾',
      '🧑🏻‍🫯‍🧑🏿',
      '🧑🏼‍🫯‍🧑🏻',
      '🧑🏼‍🫯‍🧑🏽',
      '🧑🏼‍🫯‍🧑🏾',
      '🧑🏼‍🫯‍🧑🏿',
      '🧑🏽‍🫯‍🧑🏻',
      '🧑🏽‍🫯‍🧑🏼',
      '🧑🏽‍🫯‍🧑🏾',
      '🧑🏽‍🫯‍🧑🏿',
      '🧑🏾‍🫯‍🧑🏻',
      '🧑🏾‍🫯‍🧑🏼',
      '🧑🏾‍🫯‍🧑🏽',
      '🧑🏾‍🫯‍🧑🏿',
      '🧑🏿‍🫯‍🧑🏻',
      '🧑🏿‍🫯‍🧑🏼',
      '🧑🏿‍🫯‍🧑🏽',
      '🧑🏿‍🫯‍🧑🏾',
      '👨🏻‍🫯‍👨🏼',
      '👨🏻‍🫯‍👨🏽',
      '👨🏻‍🫯‍👨🏾',
      '👨🏻‍🫯‍👨🏿',
      '👨🏼‍🫯‍👨🏻',
      '👨🏼‍🫯‍👨🏽',
      '👨🏼‍🫯‍👨🏾',
      '👨🏼‍🫯‍👨🏿',
      '👨🏽‍🫯‍👨🏻',
      '👨🏽‍🫯‍👨🏼',
      '👨🏽‍🫯‍👨🏾',
      '👨🏽‍🫯‍👨🏿',
      '👨🏾‍🫯‍👨🏻',
      '👨🏾‍🫯‍👨🏼',
      '👨🏾‍🫯‍👨🏽',
      '👨🏾‍🫯‍👨🏿',
      '👨🏿‍🫯‍👨🏻',
      '👨🏿‍🫯‍👨🏼',
      '👨🏿‍🫯‍👨🏽',
      '👨🏿‍🫯‍👨🏾',
      '👩🏻‍🫯‍👩🏼',
      '👩🏻‍🫯‍👩🏽',
      '👩🏻‍🫯‍👩🏾',
      '👩🏻‍🫯‍👩🏿',
      '👩🏼‍🫯‍👩🏻',
      '👩🏼‍🫯‍👩🏽',
      '👩🏼‍🫯‍👩🏾',
      '👩🏼‍🫯‍👩🏿',
      '👩🏽‍🫯‍👩🏻',
      '👩🏽‍🫯‍👩🏼',
      '👩🏽‍🫯‍👩🏾',
      '👩🏽‍🫯‍👩🏿',
      '👩🏾‍🫯‍👩🏻',
      '👩🏾‍🫯‍👩🏼',
      '👩🏾‍🫯‍👩🏽',
      '👩🏾‍🫯‍👩🏿',
      '👩🏿‍🫯‍👩🏻',
      '👩🏿‍🫯‍👩🏼',
      '👩🏿‍🫯‍👩🏽',
      '👩🏿‍🫯‍👩🏾',
      '🤽',
      '🤽🏻',
      '🤽🏼',
      '🤽🏽',
      '🤽🏾',
      '🤽🏿',
      '🤽‍♂️',
      '🤽🏻‍♂️',
      '🤽🏼‍♂️',
      '🤽🏽‍♂️',
      '🤽🏾‍♂️',
      '🤽🏿‍♂️',
      '🤽‍♀️',
      '🤽🏻‍♀️',
      '🤽🏼‍♀️',
      '🤽🏽‍♀️',
      '🤽🏾‍♀️',
      '🤽🏿‍♀️',
      '🤾',
      '🤾🏻',
      '🤾🏼',
      '🤾🏽',
      '🤾🏾',
      '🤾🏿',
      '🤾‍♂️',
      '🤾🏻‍♂️',
      '🤾🏼‍♂️',
      '🤾🏽‍♂️',
      '🤾🏾‍♂️',
      '🤾🏿‍♂️',
      '🤾‍♀️',
      '🤾🏻‍♀️',
      '🤾🏼‍♀️',
      '🤾🏽‍♀️',
      '🤾🏾‍♀️',
      '🤾🏿‍♀️',
      '🤹',
      '🤹🏻',
      '🤹🏼',
      '🤹🏽',
      '🤹🏾',
      '🤹🏿',
      '🤹‍♂️',
      '🤹🏻‍♂️',
      '🤹🏼‍♂️',
      '🤹🏽‍♂️',
      '🤹🏾‍♂️',
      '🤹🏿‍♂️',
      '🤹‍♀️',
      '🤹🏻‍♀️',
      '🤹🏼‍♀️',
      '🤹🏽‍♀️',
      '🤹🏾‍♀️',
      '🤹🏿‍♀️',
      '🧘',
      '🧘🏻',
      '🧘🏼',
      '🧘🏽',
      '🧘🏾',
      '🧘🏿',
      '🧘‍♂️',
      '🧘🏻‍♂️',
      '🧘🏼‍♂️',
      '🧘🏽‍♂️',
      '🧘🏾‍♂️',
      '🧘🏿‍♂️',
      '🧘‍♀️',
      '🧘🏻‍♀️',
      '🧘🏼‍♀️',
      '🧘🏽‍♀️',
      '🧘🏾‍♀️',
      '🧘🏿‍♀️',
      '🛀',
      '🛀🏻',
      '🛀🏼',
      '🛀🏽',
      '🛀🏾',
      '🛀🏿',
      '🛌',
      '🛌🏻',
      '🛌🏼',
      '🛌🏽',
      '🛌🏾',
      '🛌🏿',
      '🧑‍🤝‍🧑',
      '🧑🏻‍🤝‍🧑🏻',
      '🧑🏻‍🤝‍🧑🏼',
      '🧑🏻‍🤝‍🧑🏽',
      '🧑🏻‍🤝‍🧑🏾',
      '🧑🏻‍🤝‍🧑🏿',
      '🧑🏼‍🤝‍🧑🏻',
      '🧑🏼‍🤝‍🧑🏼',
      '🧑🏼‍🤝‍🧑🏽',
      '🧑🏼‍🤝‍🧑🏾',
      '🧑🏼‍🤝‍🧑🏿',
      '🧑🏽‍🤝‍🧑🏻',
      '🧑🏽‍🤝‍🧑🏼',
      '🧑🏽‍🤝‍🧑🏽',
      '🧑🏽‍🤝‍🧑🏾',
      '🧑🏽‍🤝‍🧑🏿',
      '🧑🏾‍🤝‍🧑🏻',
      '🧑🏾‍🤝‍🧑🏼',
      '🧑🏾‍🤝‍🧑🏽',
      '🧑🏾‍🤝‍🧑🏾',
      '🧑🏾‍🤝‍🧑🏿',
      '🧑🏿‍🤝‍🧑🏻',
      '🧑🏿‍🤝‍🧑🏼',
      '🧑🏿‍🤝‍🧑🏽',
      '🧑🏿‍🤝‍🧑🏾',
      '🧑🏿‍🤝‍🧑🏿',
      '👭',
      '👭🏻',
      '👩🏻‍🤝‍👩🏼',
      '👩🏻‍🤝‍👩🏽',
      '👩🏻‍🤝‍👩🏾',
      '👩🏻‍🤝‍👩🏿',
      '👩🏼‍🤝‍👩🏻',
      '👭🏼',
      '👩🏼‍🤝‍👩🏽',
      '👩🏼‍🤝‍👩🏾',
      '👩🏼‍🤝‍👩🏿',
      '👩🏽‍🤝‍👩🏻',
      '👩🏽‍🤝‍👩🏼',
      '👭🏽',
      '👩🏽‍🤝‍👩🏾',
      '👩🏽‍🤝‍👩🏿',
      '👩🏾‍🤝‍👩🏻',
      '👩🏾‍🤝‍👩🏼',
      '👩🏾‍🤝‍👩🏽',
      '👭🏾',
      '👩🏾‍🤝‍👩🏿',
      '👩🏿‍🤝‍👩🏻',
      '👩🏿‍🤝‍👩🏼',
      '👩🏿‍🤝‍👩🏽',
      '👩🏿‍🤝‍👩🏾',
      '👭🏿',
      '👫',
      '👫🏻',
      '👩🏻‍🤝‍👨🏼',
      '👩🏻‍🤝‍👨🏽',
      '👩🏻‍🤝‍👨🏾',
      '👩🏻‍🤝‍👨🏿',
      '👩🏼‍🤝‍👨🏻',
      '👫🏼',
      '👩🏼‍🤝‍👨🏽',
      '👩🏼‍🤝‍👨🏾',
      '👩🏼‍🤝‍👨🏿',
      '👩🏽‍🤝‍👨🏻',
      '👩🏽‍🤝‍👨🏼',
      '👫🏽',
      '👩🏽‍🤝‍👨🏾',
      '👩🏽‍🤝‍👨🏿',
      '👩🏾‍🤝‍👨🏻',
      '👩🏾‍🤝‍👨🏼',
      '👩🏾‍🤝‍👨🏽',
      '👫🏾',
      '👩🏾‍🤝‍👨🏿',
      '👩🏿‍🤝‍👨🏻',
      '👩🏿‍🤝‍👨🏼',
      '👩🏿‍🤝‍👨🏽',
      '👩🏿‍🤝‍👨🏾',
      '👫🏿',
      '👬',
      '👬🏻',
      '👨🏻‍🤝‍👨🏼',
      '👨🏻‍🤝‍👨🏽',
      '👨🏻‍🤝‍👨🏾',
      '👨🏻‍🤝‍👨🏿',
      '👨🏼‍🤝‍👨🏻',
      '👬🏼',
      '👨🏼‍🤝‍👨🏽',
      '👨🏼‍🤝‍👨🏾',
      '👨🏼‍🤝‍👨🏿',
      '👨🏽‍🤝‍👨🏻',
      '👨🏽‍🤝‍👨🏼',
      '👬🏽',
      '👨🏽‍🤝‍👨🏾',
      '👨🏽‍🤝‍👨🏿',
      '👨🏾‍🤝‍👨🏻',
      '👨🏾‍🤝‍👨🏼',
      '👨🏾‍🤝‍👨🏽',
      '👬🏾',
      '👨🏾‍🤝‍👨🏿',
      '👨🏿‍🤝‍👨🏻',
      '👨🏿‍🤝‍👨🏼',
      '👨🏿‍🤝‍👨🏽',
      '👨🏿‍🤝‍👨🏾',
      '👬🏿',
      '💏',
      '💏🏻',
      '💏🏼',
      '💏🏽',
      '💏🏾',
      '💏🏿',
      '🧑🏻‍❤️‍💋‍🧑🏼',
      '🧑🏻‍❤️‍💋‍🧑🏽',
      '🧑🏻‍❤️‍💋‍🧑🏾',
      '🧑🏻‍❤️‍💋‍🧑🏿',
      '🧑🏼‍❤️‍💋‍🧑🏻',
      '🧑🏼‍❤️‍💋‍🧑🏽',
      '🧑🏼‍❤️‍💋‍🧑🏾',
      '🧑🏼‍❤️‍💋‍🧑🏿',
      '🧑🏽‍❤️‍💋‍🧑🏻',
      '🧑🏽‍❤️‍💋‍🧑🏼',
      '🧑🏽‍❤️‍💋‍🧑🏾',
      '🧑🏽‍❤️‍💋‍🧑🏿',
      '🧑🏾‍❤️‍💋‍🧑🏻',
      '🧑🏾‍❤️‍💋‍🧑🏼',
      '🧑🏾‍❤️‍💋‍🧑🏽',
      '🧑🏾‍❤️‍💋‍🧑🏿',
      '🧑🏿‍❤️‍💋‍🧑🏻',
      '🧑🏿‍❤️‍💋‍🧑🏼',
      '🧑🏿‍❤️‍💋‍🧑🏽',
      '🧑🏿‍❤️‍💋‍🧑🏾',
      '👩‍❤️‍💋‍👨',
      '👩🏻‍❤️‍💋‍👨🏻',
      '👩🏻‍❤️‍💋‍👨🏼',
      '👩🏻‍❤️‍💋‍👨🏽',
      '👩🏻‍❤️‍💋‍👨🏾',
      '👩🏻‍❤️‍💋‍👨🏿',
      '👩🏼‍❤️‍💋‍👨🏻',
      '👩🏼‍❤️‍💋‍👨🏼',
      '👩🏼‍❤️‍💋‍👨🏽',
      '👩🏼‍❤️‍💋‍👨🏾',
      '👩🏼‍❤️‍💋‍👨🏿',
      '👩🏽‍❤️‍💋‍👨🏻',
      '👩🏽‍❤️‍💋‍👨🏼',
      '👩🏽‍❤️‍💋‍👨🏽',
      '👩🏽‍❤️‍💋‍👨🏾',
      '👩🏽‍❤️‍💋‍👨🏿',
      '👩🏾‍❤️‍💋‍👨🏻',
      '👩🏾‍❤️‍💋‍👨🏼',
      '👩🏾‍❤️‍💋‍👨🏽',
      '👩🏾‍❤️‍💋‍👨🏾',
      '👩🏾‍❤️‍💋‍👨🏿',
      '👩🏿‍❤️‍💋‍👨🏻',
      '👩🏿‍❤️‍💋‍👨🏼',
      '👩🏿‍❤️‍💋‍👨🏽',
      '👩🏿‍❤️‍💋‍👨🏾',
      '👩🏿‍❤️‍💋‍👨🏿',
      '👨‍❤️‍💋‍👨',
      '👨🏻‍❤️‍💋‍👨🏻',
      '👨🏻‍❤️‍💋‍👨🏼',
      '👨🏻‍❤️‍💋‍👨🏽',
      '👨🏻‍❤️‍💋‍👨🏾',
      '👨🏻‍❤️‍💋‍👨🏿',
      '👨🏼‍❤️‍💋‍👨🏻',
      '👨🏼‍❤️‍💋‍👨🏼',
      '👨🏼‍❤️‍💋‍👨🏽',
      '👨🏼‍❤️‍💋‍👨🏾',
      '👨🏼‍❤️‍💋‍👨🏿',
      '👨🏽‍❤️‍💋‍👨🏻',
      '👨🏽‍❤️‍💋‍👨🏼',
      '👨🏽‍❤️‍💋‍👨🏽',
      '👨🏽‍❤️‍💋‍👨🏾',
      '👨🏽‍❤️‍💋‍👨🏿',
      '👨🏾‍❤️‍💋‍👨🏻',
      '👨🏾‍❤️‍💋‍👨🏼',
      '👨🏾‍❤️‍💋‍👨🏽',
      '👨🏾‍❤️‍💋‍👨🏾',
      '👨🏾‍❤️‍💋‍👨🏿',
      '👨🏿‍❤️‍💋‍👨🏻',
      '👨🏿‍❤️‍💋‍👨🏼',
      '👨🏿‍❤️‍💋‍👨🏽',
      '👨🏿‍❤️‍💋‍👨🏾',
      '👨🏿‍❤️‍💋‍👨🏿',
      '👩‍❤️‍💋‍👩',
      '👩🏻‍❤️‍💋‍👩🏻',
      '👩🏻‍❤️‍💋‍👩🏼',
      '👩🏻‍❤️‍💋‍👩🏽',
      '👩🏻‍❤️‍💋‍👩🏾',
      '👩🏻‍❤️‍💋‍👩🏿',
      '👩🏼‍❤️‍💋‍👩🏻',
      '👩🏼‍❤️‍💋‍👩🏼',
      '👩🏼‍❤️‍💋‍👩🏽',
      '👩🏼‍❤️‍💋‍👩🏾',
      '👩🏼‍❤️‍💋‍👩🏿',
      '👩🏽‍❤️‍💋‍👩🏻',
      '👩🏽‍❤️‍💋‍👩🏼',
      '👩🏽‍❤️‍💋‍👩🏽',
      '👩🏽‍❤️‍💋‍👩🏾',
      '👩🏽‍❤️‍💋‍👩🏿',
      '👩🏾‍❤️‍💋‍👩🏻',
      '👩🏾‍❤️‍💋‍👩🏼',
      '👩🏾‍❤️‍💋‍👩🏽',
      '👩🏾‍❤️‍💋‍👩🏾',
      '👩🏾‍❤️‍💋‍👩🏿',
      '👩🏿‍❤️‍💋‍👩🏻',
      '👩🏿‍❤️‍💋‍👩🏼',
      '👩🏿‍❤️‍💋‍👩🏽',
      '👩🏿‍❤️‍💋‍👩🏾',
      '👩🏿‍❤️‍💋‍👩🏿',
      '💑',
      '💑🏻',
      '💑🏼',
      '💑🏽',
      '💑🏾',
      '💑🏿',
      '🧑🏻‍❤️‍🧑🏼',
      '🧑🏻‍❤️‍🧑🏽',
      '🧑🏻‍❤️‍🧑🏾',
      '🧑🏻‍❤️‍🧑🏿',
      '🧑🏼‍❤️‍🧑🏻',
      '🧑🏼‍❤️‍🧑🏽',
      '🧑🏼‍❤️‍🧑🏾',
      '🧑🏼‍❤️‍🧑🏿',
      '🧑🏽‍❤️‍🧑🏻',
      '🧑🏽‍❤️‍🧑🏼',
      '🧑🏽‍❤️‍🧑🏾',
      '🧑🏽‍❤️‍🧑🏿',
      '🧑🏾‍❤️‍🧑🏻',
      '🧑🏾‍❤️‍🧑🏼',
      '🧑🏾‍❤️‍🧑🏽',
      '🧑🏾‍❤️‍🧑🏿',
      '🧑🏿‍❤️‍🧑🏻',
      '🧑🏿‍❤️‍🧑🏼',
      '🧑🏿‍❤️‍🧑🏽',
      '🧑🏿‍❤️‍🧑🏾',
      '👩‍❤️‍👨',
      '👩🏻‍❤️‍👨🏻',
      '👩🏻‍❤️‍👨🏼',
      '👩🏻‍❤️‍👨🏽',
      '👩🏻‍❤️‍👨🏾',
      '👩🏻‍❤️‍👨🏿',
      '👩🏼‍❤️‍👨🏻',
      '👩🏼‍❤️‍👨🏼',
      '👩🏼‍❤️‍👨🏽',
      '👩🏼‍❤️‍👨🏾',
      '👩🏼‍❤️‍👨🏿',
      '👩🏽‍❤️‍👨🏻',
      '👩🏽‍❤️‍👨🏼',
      '👩🏽‍❤️‍👨🏽',
      '👩🏽‍❤️‍👨🏾',
      '👩🏽‍❤️‍👨🏿',
      '👩🏾‍❤️‍👨🏻',
      '👩🏾‍❤️‍👨🏼',
      '👩🏾‍❤️‍👨🏽',
      '👩🏾‍❤️‍👨🏾',
      '👩🏾‍❤️‍👨🏿',
      '👩🏿‍❤️‍👨🏻',
      '👩🏿‍❤️‍👨🏼',
      '👩🏿‍❤️‍👨🏽',
      '👩🏿‍❤️‍👨🏾',
      '👩🏿‍❤️‍👨🏿',
      '👨‍❤️‍👨',
      '👨🏻‍❤️‍👨🏻',
      '👨🏻‍❤️‍👨🏼',
      '👨🏻‍❤️‍👨🏽',
      '👨🏻‍❤️‍👨🏾',
      '👨🏻‍❤️‍👨🏿',
      '👨🏼‍❤️‍👨🏻',
      '👨🏼‍❤️‍👨🏼',
      '👨🏼‍❤️‍👨🏽',
      '👨🏼‍❤️‍👨🏾',
      '👨🏼‍❤️‍👨🏿',
      '👨🏽‍❤️‍👨🏻',
      '👨🏽‍❤️‍👨🏼',
      '👨🏽‍❤️‍👨🏽',
      '👨🏽‍❤️‍👨🏾',
      '👨🏽‍❤️‍👨🏿',
      '👨🏾‍❤️‍👨🏻',
      '👨🏾‍❤️‍👨🏼',
      '👨🏾‍❤️‍👨🏽',
      '👨🏾‍❤️‍👨🏾',
      '👨🏾‍❤️‍👨🏿',
      '👨🏿‍❤️‍👨🏻',
      '👨🏿‍❤️‍👨🏼',
      '👨🏿‍❤️‍👨🏽',
      '👨🏿‍❤️‍👨🏾',
      '👨🏿‍❤️‍👨🏿',
      '👩‍❤️‍👩',
      '👩🏻‍❤️‍👩🏻',
      '👩🏻‍❤️‍👩🏼',
      '👩🏻‍❤️‍👩🏽',
      '👩🏻‍❤️‍👩🏾',
      '👩🏻‍❤️‍👩🏿',
      '👩🏼‍❤️‍👩🏻',
      '👩🏼‍❤️‍👩🏼',
      '👩🏼‍❤️‍👩🏽',
      '👩🏼‍❤️‍👩🏾',
      '👩🏼‍❤️‍👩🏿',
      '👩🏽‍❤️‍👩🏻',
      '👩🏽‍❤️‍👩🏼',
      '👩🏽‍❤️‍👩🏽',
      '👩🏽‍❤️‍👩🏾',
      '👩🏽‍❤️‍👩🏿',
      '👩🏾‍❤️‍👩🏻',
      '👩🏾‍❤️‍👩🏼',
      '👩🏾‍❤️‍👩🏽',
      '👩🏾‍❤️‍👩🏾',
      '👩🏾‍❤️‍👩🏿',
      '👩🏿‍❤️‍👩🏻',
      '👩🏿‍❤️‍👩🏼',
      '👩🏿‍❤️‍👩🏽',
      '👩🏿‍❤️‍👩🏾',
      '👩🏿‍❤️‍👩🏿',
      '👨‍👩‍👦',
      '👨‍👩‍👧',
      '👨‍👩‍👧‍👦',
      '👨‍👩‍👦‍👦',
      '👨‍👩‍👧‍👧',
      '👨‍👨‍👦',
      '👨‍👨‍👧',
      '👨‍👨‍👧‍👦',
      '👨‍👨‍👦‍👦',
      '👨‍👨‍👧‍👧',
      '👩‍👩‍👦',
      '👩‍👩‍👧',
      '👩‍👩‍👧‍👦',
      '👩‍👩‍👦‍👦',
      '👩‍👩‍👧‍👧',
      '👨‍👦',
      '👨‍👦‍👦',
      '👨‍👧',
      '👨‍👧‍👦',
      '👨‍👧‍👧',
      '👩‍👦',
      '👩‍👦‍👦',
      '👩‍👧',
      '👩‍👧‍👦',
      '👩‍👧‍👧',
      '🗣️',
      '👤',
      '👥',
      '🫂',
      '👪',
      '🧑‍🧑‍🧒',
      '🧑‍🧑‍🧒‍🧒',
      '🧑‍🧒',
      '🧑‍🧒‍🧒',
      '👣',
      '🫆',
    ],
  ),
  EmojiReactionSection(
    label: 'Corazones',
    icon: '💖',
    emojis: [
      '💌',
      '💘',
      '💝',
      '💖',
      '💗',
      '💓',
      '💞',
      '💕',
      '💟',
      '❣️',
      '💔',
      '❤️‍🔥',
      '❤️‍🩹',
      '❤️',
      '🩷',
      '🧡',
      '💛',
      '💚',
      '💙',
      '🩵',
      '💜',
      '🤎',
      '🖤',
      '🩶',
      '🤍',
      '💋',
      '💯',
      '💢',
      '🫯',
      '💥',
      '💫',
      '💦',
      '💨',
      '🕳️',
      '💬',
      '👁️‍🗨️',
      '🗨️',
      '🗯️',
      '💭',
      '💤',
    ],
  ),
  EmojiReactionSection(
    label: 'Naturaleza',
    icon: '🌿',
    emojis: [
      '🐵',
      '🐒',
      '🦍',
      '🦧',
      '🐶',
      '🐕',
      '🦮',
      '🐕‍🦺',
      '🐩',
      '🐺',
      '🦊',
      '🦝',
      '🐱',
      '🐈',
      '🐈‍⬛',
      '🦁',
      '🐯',
      '🐅',
      '🐆',
      '🐴',
      '🫎',
      '🫏',
      '🐎',
      '🦄',
      '🦓',
      '🦌',
      '🦬',
      '🐮',
      '🐂',
      '🐃',
      '🐄',
      '🐷',
      '🐖',
      '🐗',
      '🐽',
      '🐏',
      '🐑',
      '🐐',
      '🐪',
      '🐫',
      '🦙',
      '🦒',
      '🐘',
      '🦣',
      '🦏',
      '🦛',
      '🐭',
      '🐁',
      '🐀',
      '🐹',
      '🐰',
      '🐇',
      '🐿️',
      '🦫',
      '🦔',
      '🦇',
      '🐻',
      '🐻‍❄️',
      '🐨',
      '🐼',
      '🦥',
      '🦦',
      '🦨',
      '🦘',
      '🦡',
      '🐾',
      '🦃',
      '🐔',
      '🐓',
      '🐣',
      '🐤',
      '🐥',
      '🐦',
      '🐧',
      '🕊️',
      '🦅',
      '🦆',
      '🦢',
      '🦉',
      '🦤',
      '🪶',
      '🦩',
      '🦚',
      '🦜',
      '🪽',
      '🐦‍⬛',
      '🪿',
      '🐦‍🔥',
      '🐸',
      '🐊',
      '🐢',
      '🦎',
      '🐍',
      '🐲',
      '🐉',
      '🦕',
      '🦖',
      '🐳',
      '🐋',
      '🐬',
      '🫍',
      '🦭',
      '🐟',
      '🐠',
      '🐡',
      '🦈',
      '🐙',
      '🐚',
      '🪸',
      '🪼',
      '🦀',
      '🦞',
      '🦐',
      '🦑',
      '🦪',
      '🐌',
      '🦋',
      '🐛',
      '🐜',
      '🐝',
      '🪲',
      '🐞',
      '🦗',
      '🪳',
      '🕷️',
      '🕸️',
      '🦂',
      '🦟',
      '🪰',
      '🪱',
      '🦠',
      '💐',
      '🌸',
      '💮',
      '🪷',
      '🏵️',
      '🌹',
      '🥀',
      '🌺',
      '🌻',
      '🌼',
      '🌷',
      '🪻',
      '🌱',
      '🪴',
      '🌲',
      '🌳',
      '🌴',
      '🌵',
      '🌾',
      '🌿',
      '☘️',
      '🍀',
      '🍁',
      '🍂',
      '🍃',
      '🪹',
      '🪺',
      '🍄',
      '🪾',
    ],
  ),
  EmojiReactionSection(
    label: 'Comida',
    icon: '🍕',
    emojis: [
      '🍇',
      '🍈',
      '🍉',
      '🍊',
      '🍋',
      '🍋‍🟩',
      '🍌',
      '🍍',
      '🥭',
      '🍎',
      '🍏',
      '🍐',
      '🍑',
      '🍒',
      '🍓',
      '🫐',
      '🥝',
      '🍅',
      '🫒',
      '🥥',
      '🥑',
      '🍆',
      '🥔',
      '🥕',
      '🌽',
      '🌶️',
      '🫑',
      '🥒',
      '🥬',
      '🥦',
      '🧄',
      '🧅',
      '🥜',
      '🫘',
      '🌰',
      '🫚',
      '🫛',
      '🍄‍🟫',
      '🫜',
      '🍞',
      '🥐',
      '🥖',
      '🫓',
      '🥨',
      '🥯',
      '🥞',
      '🧇',
      '🧀',
      '🍖',
      '🍗',
      '🥩',
      '🥓',
      '🍔',
      '🍟',
      '🍕',
      '🌭',
      '🥪',
      '🌮',
      '🌯',
      '🫔',
      '🥙',
      '🧆',
      '🥚',
      '🍳',
      '🥘',
      '🍲',
      '🫕',
      '🥣',
      '🥗',
      '🍿',
      '🧈',
      '🧂',
      '🥫',
      '🍱',
      '🍘',
      '🍙',
      '🍚',
      '🍛',
      '🍜',
      '🍝',
      '🍠',
      '🍢',
      '🍣',
      '🍤',
      '🍥',
      '🥮',
      '🍡',
      '🥟',
      '🥠',
      '🥡',
      '🍦',
      '🍧',
      '🍨',
      '🍩',
      '🍪',
      '🎂',
      '🍰',
      '🧁',
      '🥧',
      '🍫',
      '🍬',
      '🍭',
      '🍮',
      '🍯',
      '🍼',
      '🥛',
      '☕',
      '🫖',
      '🍵',
      '🍶',
      '🍾',
      '🍷',
      '🍸',
      '🍹',
      '🍺',
      '🍻',
      '🥂',
      '🥃',
      '🫗',
      '🥤',
      '🧋',
      '🧃',
      '🧉',
      '🧊',
      '🥢',
      '🍽️',
      '🍴',
      '🥄',
      '🔪',
      '🫙',
      '🏺',
    ],
  ),
  EmojiReactionSection(
    label: 'Planes',
    icon: '⚽',
    emojis: [
      '🎃',
      '🎄',
      '🎆',
      '🎇',
      '🧨',
      '✨',
      '🎈',
      '🎉',
      '🎊',
      '🎋',
      '🎍',
      '🎎',
      '🎏',
      '🎐',
      '🎑',
      '🧧',
      '🎀',
      '🎁',
      '🎗️',
      '🎟️',
      '🎫',
      '🎖️',
      '🏆',
      '🏅',
      '🥇',
      '🥈',
      '🥉',
      '⚽',
      '⚾',
      '🥎',
      '🏀',
      '🏐',
      '🏈',
      '🏉',
      '🎾',
      '🥏',
      '🎳',
      '🏏',
      '🏑',
      '🏒',
      '🥍',
      '🏓',
      '🏸',
      '🥊',
      '🥋',
      '🥅',
      '⛳',
      '⛸️',
      '🎣',
      '🤿',
      '🎽',
      '🎿',
      '🛷',
      '🥌',
      '🎯',
      '🪀',
      '🪁',
      '🔫',
      '🎱',
      '🔮',
      '🪄',
      '🎮',
      '🕹️',
      '🎰',
      '🎲',
      '🧩',
      '🧸',
      '🪅',
      '🪩',
      '🪆',
      '♠️',
      '♥️',
      '♦️',
      '♣️',
      '♟️',
      '🃏',
      '🀄',
      '🎴',
      '🎭',
      '🖼️',
      '🎨',
      '🧵',
      '🪡',
      '🧶',
      '🪢',
    ],
  ),
  EmojiReactionSection(
    label: 'Viajes',
    icon: '✈️',
    emojis: [
      '🌍',
      '🌎',
      '🌏',
      '🌐',
      '🗺️',
      '🗾',
      '🧭',
      '🏔️',
      '⛰️',
      '🛘',
      '🌋',
      '🗻',
      '🏕️',
      '🏖️',
      '🏜️',
      '🏝️',
      '🏞️',
      '🏟️',
      '🏛️',
      '🏗️',
      '🧱',
      '🪨',
      '🪵',
      '🛖',
      '🏘️',
      '🏚️',
      '🏠',
      '🏡',
      '🏢',
      '🏣',
      '🏤',
      '🏥',
      '🏦',
      '🏨',
      '🏩',
      '🏪',
      '🏫',
      '🏬',
      '🏭',
      '🏯',
      '🏰',
      '💒',
      '🗼',
      '🗽',
      '⛪',
      '🕌',
      '🛕',
      '🕍',
      '⛩️',
      '🕋',
      '⛲',
      '⛺',
      '🌁',
      '🌃',
      '🏙️',
      '🌄',
      '🌅',
      '🌆',
      '🌇',
      '🌉',
      '♨️',
      '🎠',
      '🛝',
      '🎡',
      '🎢',
      '💈',
      '🎪',
      '🚂',
      '🚃',
      '🚄',
      '🚅',
      '🚆',
      '🚇',
      '🚈',
      '🚉',
      '🚊',
      '🚝',
      '🚞',
      '🚋',
      '🚌',
      '🚍',
      '🚎',
      '🚐',
      '🚑',
      '🚒',
      '🚓',
      '🚔',
      '🚕',
      '🚖',
      '🚗',
      '🚘',
      '🚙',
      '🛻',
      '🚚',
      '🚛',
      '🚜',
      '🏎️',
      '🏍️',
      '🛵',
      '🦽',
      '🦼',
      '🛺',
      '🚲',
      '🛴',
      '🛹',
      '🛼',
      '🚏',
      '🛣️',
      '🛤️',
      '🛢️',
      '⛽',
      '🛞',
      '🚨',
      '🚥',
      '🚦',
      '🛑',
      '🚧',
      '⚓',
      '🛟',
      '⛵',
      '🛶',
      '🚤',
      '🛳️',
      '⛴️',
      '🛥️',
      '🚢',
      '✈️',
      '🛩️',
      '🛫',
      '🛬',
      '🪂',
      '💺',
      '🚁',
      '🚟',
      '🚠',
      '🚡',
      '🛰️',
      '🚀',
      '🛸',
      '🛎️',
      '🧳',
      '⌛',
      '⏳',
      '⌚',
      '⏰',
      '⏱️',
      '⏲️',
      '🕰️',
      '🕛',
      '🕧',
      '🕐',
      '🕜',
      '🕑',
      '🕝',
      '🕒',
      '🕞',
      '🕓',
      '🕟',
      '🕔',
      '🕠',
      '🕕',
      '🕡',
      '🕖',
      '🕢',
      '🕗',
      '🕣',
      '🕘',
      '🕤',
      '🕙',
      '🕥',
      '🕚',
      '🕦',
      '🌑',
      '🌒',
      '🌓',
      '🌔',
      '🌕',
      '🌖',
      '🌗',
      '🌘',
      '🌙',
      '🌚',
      '🌛',
      '🌜',
      '🌡️',
      '☀️',
      '🌝',
      '🌞',
      '🪐',
      '⭐',
      '🌟',
      '🌠',
      '🌌',
      '☁️',
      '⛅',
      '⛈️',
      '🌤️',
      '🌥️',
      '🌦️',
      '🌧️',
      '🌨️',
      '🌩️',
      '🌪️',
      '🌫️',
      '🌬️',
      '🌀',
      '🌈',
      '🌂',
      '☂️',
      '☔',
      '⛱️',
      '⚡',
      '❄️',
      '☃️',
      '⛄',
      '☄️',
      '🔥',
      '💧',
      '🌊',
    ],
  ),
  EmojiReactionSection(
    label: 'Objetos',
    icon: '💡',
    emojis: [
      '👓',
      '🕶️',
      '🥽',
      '🥼',
      '🦺',
      '👔',
      '👕',
      '👖',
      '🧣',
      '🧤',
      '🧥',
      '🧦',
      '👗',
      '👘',
      '🥻',
      '🩱',
      '🩲',
      '🩳',
      '👙',
      '👚',
      '🪭',
      '👛',
      '👜',
      '👝',
      '🛍️',
      '🎒',
      '🩴',
      '👞',
      '👟',
      '🥾',
      '🥿',
      '👠',
      '👡',
      '🩰',
      '👢',
      '🪮',
      '👑',
      '👒',
      '🎩',
      '🎓',
      '🧢',
      '🪖',
      '⛑️',
      '📿',
      '💄',
      '💍',
      '💎',
      '🔇',
      '🔈',
      '🔉',
      '🔊',
      '📢',
      '📣',
      '📯',
      '🔔',
      '🔕',
      '🎼',
      '🎵',
      '🎶',
      '🎙️',
      '🎚️',
      '🎛️',
      '🎤',
      '🎧',
      '📻',
      '🎷',
      '🎺',
      '🪊',
      '🪗',
      '🎸',
      '🎹',
      '🎻',
      '🪕',
      '🥁',
      '🪘',
      '🪇',
      '🪈',
      '🪉',
      '📱',
      '📲',
      '☎️',
      '📞',
      '📟',
      '📠',
      '🔋',
      '🪫',
      '🔌',
      '💻',
      '🖥️',
      '🖨️',
      '⌨️',
      '🖱️',
      '🖲️',
      '💽',
      '💾',
      '💿',
      '📀',
      '🧮',
      '🎥',
      '🎞️',
      '📽️',
      '🎬',
      '📺',
      '📷',
      '📸',
      '📹',
      '📼',
      '🔍',
      '🔎',
      '🕯️',
      '💡',
      '🔦',
      '🏮',
      '🪔',
      '📔',
      '📕',
      '📖',
      '📗',
      '📘',
      '📙',
      '📚',
      '📓',
      '📒',
      '📃',
      '📜',
      '📄',
      '📰',
      '🗞️',
      '📑',
      '🔖',
      '🏷️',
      '🪙',
      '💰',
      '🪎',
      '💴',
      '💵',
      '💶',
      '💷',
      '💸',
      '💳',
      '🧾',
      '💹',
      '✉️',
      '📧',
      '📨',
      '📩',
      '📤',
      '📥',
      '📦',
      '📫',
      '📪',
      '📬',
      '📭',
      '📮',
      '🗳️',
      '✏️',
      '✒️',
      '🖋️',
      '🖊️',
      '🖌️',
      '🖍️',
      '📝',
      '💼',
      '📁',
      '📂',
      '🗂️',
      '📅',
      '📆',
      '🗒️',
      '🗓️',
      '📇',
      '📈',
      '📉',
      '📊',
      '📋',
      '📌',
      '📍',
      '📎',
      '🖇️',
      '📏',
      '📐',
      '✂️',
      '🗃️',
      '🗄️',
      '🗑️',
      '🔒',
      '🔓',
      '🔏',
      '🔐',
      '🔑',
      '🗝️',
      '🔨',
      '🪓',
      '⛏️',
      '⚒️',
      '🛠️',
      '🗡️',
      '⚔️',
      '💣',
      '🪃',
      '🏹',
      '🛡️',
      '🪚',
      '🔧',
      '🪛',
      '🔩',
      '⚙️',
      '🗜️',
      '⚖️',
      '🦯',
      '🔗',
      '⛓️‍💥',
      '⛓️',
      '🪝',
      '🧰',
      '🧲',
      '🪜',
      '🪏',
      '⚗️',
      '🧪',
      '🧫',
      '🧬',
      '🔬',
      '🔭',
      '📡',
      '💉',
      '🩸',
      '💊',
      '🩹',
      '🩼',
      '🩺',
      '🩻',
      '🚪',
      '🛗',
      '🪞',
      '🪟',
      '🛏️',
      '🛋️',
      '🪑',
      '🚽',
      '🪠',
      '🚿',
      '🛁',
      '🪤',
      '🪒',
      '🧴',
      '🧷',
      '🧹',
      '🧺',
      '🧻',
      '🪣',
      '🧼',
      '🫧',
      '🪥',
      '🧽',
      '🧯',
      '🛒',
      '🚬',
      '⚰️',
      '🪦',
      '⚱️',
      '🧿',
      '🪬',
      '🗿',
      '🪧',
      '🪪',
    ],
  ),
  EmojiReactionSection(
    label: 'Símbolos',
    icon: '✨',
    emojis: [
      '🏧',
      '🚮',
      '🚰',
      '♿',
      '🚹',
      '🚺',
      '🚻',
      '🚼',
      '🚾',
      '🛂',
      '🛃',
      '🛄',
      '🛅',
      '⚠️',
      '🚸',
      '⛔',
      '🚫',
      '🚳',
      '🚭',
      '🚯',
      '🚱',
      '🚷',
      '📵',
      '🔞',
      '☢️',
      '☣️',
      '⬆️',
      '↗️',
      '➡️',
      '↘️',
      '⬇️',
      '↙️',
      '⬅️',
      '↖️',
      '↕️',
      '↔️',
      '↩️',
      '↪️',
      '⤴️',
      '⤵️',
      '🔃',
      '🔄',
      '🔙',
      '🔚',
      '🔛',
      '🔜',
      '🔝',
      '🛐',
      '⚛️',
      '🕉️',
      '✡️',
      '☸️',
      '☯️',
      '✝️',
      '☦️',
      '☪️',
      '☮️',
      '🕎',
      '🔯',
      '🪯',
      '♈',
      '♉',
      '♊',
      '♋',
      '♌',
      '♍',
      '♎',
      '♏',
      '♐',
      '♑',
      '♒',
      '♓',
      '⛎',
      '🔀',
      '🔁',
      '🔂',
      '▶️',
      '⏩',
      '⏭️',
      '⏯️',
      '◀️',
      '⏪',
      '⏮️',
      '🔼',
      '⏫',
      '🔽',
      '⏬',
      '⏸️',
      '⏹️',
      '⏺️',
      '⏏️',
      '🎦',
      '🔅',
      '🔆',
      '📶',
      '🛜',
      '📳',
      '📴',
      '♀️',
      '♂️',
      '⚧️',
      '✖️',
      '➕',
      '➖',
      '➗',
      '🟰',
      '♾️',
      '‼️',
      '⁉️',
      '❓',
      '❔',
      '❕',
      '❗',
      '〰️',
      '💱',
      '💲',
      '⚕️',
      '♻️',
      '⚜️',
      '🔱',
      '📛',
      '🔰',
      '⭕',
      '✅',
      '☑️',
      '✔️',
      '❌',
      '❎',
      '➰',
      '➿',
      '〽️',
      '✳️',
      '✴️',
      '❇️',
      '©️',
      '®️',
      '™️',
      '🫟',
      '#️⃣',
      '*️⃣',
      '0️⃣',
      '1️⃣',
      '2️⃣',
      '3️⃣',
      '4️⃣',
      '5️⃣',
      '6️⃣',
      '7️⃣',
      '8️⃣',
      '9️⃣',
      '🔟',
      '🔠',
      '🔡',
      '🔢',
      '🔣',
      '🔤',
      '🅰️',
      '🆎',
      '🅱️',
      '🆑',
      '🆒',
      '🆓',
      'ℹ️',
      '🆔',
      'Ⓜ️',
      '🆕',
      '🆖',
      '🅾️',
      '🆗',
      '🅿️',
      '🆘',
      '🆙',
      '🆚',
      '🈁',
      '🈂️',
      '🈷️',
      '🈶',
      '🈯',
      '🉐',
      '🈹',
      '🈚',
      '🈲',
      '🉑',
      '🈸',
      '🈴',
      '🈳',
      '㊗️',
      '㊙️',
      '🈺',
      '🈵',
      '🔴',
      '🟠',
      '🟡',
      '🟢',
      '🔵',
      '🟣',
      '🟤',
      '⚫',
      '⚪',
      '🟥',
      '🟧',
      '🟨',
      '🟩',
      '🟦',
      '🟪',
      '🟫',
      '⬛',
      '⬜',
      '◼️',
      '◻️',
      '◾',
      '◽',
      '▪️',
      '▫️',
      '🔶',
      '🔷',
      '🔸',
      '🔹',
      '🔺',
      '🔻',
      '💠',
      '🔘',
      '🔳',
      '🔲',
    ],
  ),
  EmojiReactionSection(
    label: 'Banderas',
    icon: '🏳️',
    emojis: [
      '🏁',
      '🚩',
      '🎌',
      '🏴',
      '🏳️',
      '🏳️‍🌈',
      '🏳️‍⚧️',
      '🏴‍☠️',
      '🇦🇨',
      '🇦🇩',
      '🇦🇪',
      '🇦🇫',
      '🇦🇬',
      '🇦🇮',
      '🇦🇱',
      '🇦🇲',
      '🇦🇴',
      '🇦🇶',
      '🇦🇷',
      '🇦🇸',
      '🇦🇹',
      '🇦🇺',
      '🇦🇼',
      '🇦🇽',
      '🇦🇿',
      '🇧🇦',
      '🇧🇧',
      '🇧🇩',
      '🇧🇪',
      '🇧🇫',
      '🇧🇬',
      '🇧🇭',
      '🇧🇮',
      '🇧🇯',
      '🇧🇱',
      '🇧🇲',
      '🇧🇳',
      '🇧🇴',
      '🇧🇶',
      '🇧🇷',
      '🇧🇸',
      '🇧🇹',
      '🇧🇻',
      '🇧🇼',
      '🇧🇾',
      '🇧🇿',
      '🇨🇦',
      '🇨🇨',
      '🇨🇩',
      '🇨🇫',
      '🇨🇬',
      '🇨🇭',
      '🇨🇮',
      '🇨🇰',
      '🇨🇱',
      '🇨🇲',
      '🇨🇳',
      '🇨🇴',
      '🇨🇵',
      '🇨🇶',
      '🇨🇷',
      '🇨🇺',
      '🇨🇻',
      '🇨🇼',
      '🇨🇽',
      '🇨🇾',
      '🇨🇿',
      '🇩🇪',
      '🇩🇬',
      '🇩🇯',
      '🇩🇰',
      '🇩🇲',
      '🇩🇴',
      '🇩🇿',
      '🇪🇦',
      '🇪🇨',
      '🇪🇪',
      '🇪🇬',
      '🇪🇭',
      '🇪🇷',
      '🇪🇸',
      '🇪🇹',
      '🇪🇺',
      '🇫🇮',
      '🇫🇯',
      '🇫🇰',
      '🇫🇲',
      '🇫🇴',
      '🇫🇷',
      '🇬🇦',
      '🇬🇧',
      '🇬🇩',
      '🇬🇪',
      '🇬🇫',
      '🇬🇬',
      '🇬🇭',
      '🇬🇮',
      '🇬🇱',
      '🇬🇲',
      '🇬🇳',
      '🇬🇵',
      '🇬🇶',
      '🇬🇷',
      '🇬🇸',
      '🇬🇹',
      '🇬🇺',
      '🇬🇼',
      '🇬🇾',
      '🇭🇰',
      '🇭🇲',
      '🇭🇳',
      '🇭🇷',
      '🇭🇹',
      '🇭🇺',
      '🇮🇨',
      '🇮🇩',
      '🇮🇪',
      '🇮🇱',
      '🇮🇲',
      '🇮🇳',
      '🇮🇴',
      '🇮🇶',
      '🇮🇷',
      '🇮🇸',
      '🇮🇹',
      '🇯🇪',
      '🇯🇲',
      '🇯🇴',
      '🇯🇵',
      '🇰🇪',
      '🇰🇬',
      '🇰🇭',
      '🇰🇮',
      '🇰🇲',
      '🇰🇳',
      '🇰🇵',
      '🇰🇷',
      '🇰🇼',
      '🇰🇾',
      '🇰🇿',
      '🇱🇦',
      '🇱🇧',
      '🇱🇨',
      '🇱🇮',
      '🇱🇰',
      '🇱🇷',
      '🇱🇸',
      '🇱🇹',
      '🇱🇺',
      '🇱🇻',
      '🇱🇾',
      '🇲🇦',
      '🇲🇨',
      '🇲🇩',
      '🇲🇪',
      '🇲🇫',
      '🇲🇬',
      '🇲🇭',
      '🇲🇰',
      '🇲🇱',
      '🇲🇲',
      '🇲🇳',
      '🇲🇴',
      '🇲🇵',
      '🇲🇶',
      '🇲🇷',
      '🇲🇸',
      '🇲🇹',
      '🇲🇺',
      '🇲🇻',
      '🇲🇼',
      '🇲🇽',
      '🇲🇾',
      '🇲🇿',
      '🇳🇦',
      '🇳🇨',
      '🇳🇪',
      '🇳🇫',
      '🇳🇬',
      '🇳🇮',
      '🇳🇱',
      '🇳🇴',
      '🇳🇵',
      '🇳🇷',
      '🇳🇺',
      '🇳🇿',
      '🇴🇲',
      '🇵🇦',
      '🇵🇪',
      '🇵🇫',
      '🇵🇬',
      '🇵🇭',
      '🇵🇰',
      '🇵🇱',
      '🇵🇲',
      '🇵🇳',
      '🇵🇷',
      '🇵🇸',
      '🇵🇹',
      '🇵🇼',
      '🇵🇾',
      '🇶🇦',
      '🇷🇪',
      '🇷🇴',
      '🇷🇸',
      '🇷🇺',
      '🇷🇼',
      '🇸🇦',
      '🇸🇧',
      '🇸🇨',
      '🇸🇩',
      '🇸🇪',
      '🇸🇬',
      '🇸🇭',
      '🇸🇮',
      '🇸🇯',
      '🇸🇰',
      '🇸🇱',
      '🇸🇲',
      '🇸🇳',
      '🇸🇴',
      '🇸🇷',
      '🇸🇸',
      '🇸🇹',
      '🇸🇻',
      '🇸🇽',
      '🇸🇾',
      '🇸🇿',
      '🇹🇦',
      '🇹🇨',
      '🇹🇩',
      '🇹🇫',
      '🇹🇬',
      '🇹🇭',
      '🇹🇯',
      '🇹🇰',
      '🇹🇱',
      '🇹🇲',
      '🇹🇳',
      '🇹🇴',
      '🇹🇷',
      '🇹🇹',
      '🇹🇻',
      '🇹🇼',
      '🇹🇿',
      '🇺🇦',
      '🇺🇬',
      '🇺🇲',
      '🇺🇳',
      '🇺🇸',
      '🇺🇾',
      '🇺🇿',
      '🇻🇦',
      '🇻🇨',
      '🇻🇪',
      '🇻🇬',
      '🇻🇮',
      '🇻🇳',
      '🇻🇺',
      '🇼🇫',
      '🇼🇸',
      '🇽🇰',
      '🇾🇪',
      '🇾🇹',
      '🇿🇦',
      '🇿🇲',
      '🇿🇼',
      '🏴󠁧󠁢󠁥󠁮󠁧󠁿',
      '🏴󠁧󠁢󠁳󠁣󠁴󠁿',
      '🏴󠁧󠁢󠁷󠁬󠁳󠁿',
    ],
  ),
];

final List<String> kSundayReactionEmojis = kSundayReactionEmojiCategorySections
    .expand((section) => section.emojis)
    .toSet()
    .toList(growable: false);

final List<EmojiReactionSection> kSundayReactionEmojiSections = [
  EmojiReactionSection(
    label: 'Todos',
    icon: '😀',
    emojis: kSundayReactionEmojis,
  ),
  ...kSundayReactionEmojiCategorySections,
];

final List<String> kGroupEmojiOptions = kSundayReactionEmojis;
final List<EmojiReactionSection> kGroupEmojiSections =
    kSundayReactionEmojiSections;

const int kMaxGroupMembers = 30;

const List<Color> kGroupColorOptions = [
  ssOrange,
  Color(0xFF64B5F6),
  Color(0xFFA8D8A8),
  Color(0xFFB89AF2),
  Color(0xFFF5C2D0),
  Color(0xFFFFD36A),
  Color(0xFF78CAD2),
  Color(0xFFF27272),
  Color(0xFF78A866),
  Color(0xFFE5735A),
  Color(0xFFA989C5),
  Color(0xFF5AAAD0),
];

String? nonEmptyStringOrNull(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

Color groupColorFromValue(Object? value) {
  if (value is int) return Color(value);
  if (value is String) {
    final parsed = int.tryParse(value);
    if (parsed != null) return Color(parsed);
  }
  return ssOrange;
}

bool _isEmojiBaseCodePoint(int value) {
  return value == 0x00A9 ||
      value == 0x00AE ||
      value == 0x203C ||
      value == 0x2049 ||
      value == 0x2122 ||
      value == 0x2139 ||
      value == 0x3030 ||
      value == 0x303D ||
      value == 0x3297 ||
      value == 0x3299 ||
      value >= 0x1F000 && value <= 0x1FAFF ||
      value >= 0x2194 && value <= 0x21AA ||
      value >= 0x231A && value <= 0x231B ||
      value == 0x2328 ||
      value == 0x23CF ||
      value >= 0x23E9 && value <= 0x23F3 ||
      value >= 0x23F8 && value <= 0x23FA ||
      value == 0x24C2 ||
      value >= 0x25AA && value <= 0x25AB ||
      value == 0x25B6 ||
      value == 0x25C0 ||
      value >= 0x25FB && value <= 0x25FE ||
      value >= 0x2600 && value <= 0x27BF ||
      value >= 0x2934 && value <= 0x2935 ||
      value >= 0x2B05 && value <= 0x2B55;
}

bool _isEmojiSequenceCodePoint(int value) {
  return _isEmojiBaseCodePoint(value) ||
      value == 0x200D ||
      value == 0x20E3 ||
      value == 0xFE0E ||
      value == 0xFE0F ||
      value >= 0x0030 && value <= 0x0039 ||
      value >= 0xE0020 && value <= 0xE007F ||
      value == 0x0023 ||
      value == 0x002A;
}

bool _isKeycapEmojiSequence(List<int> codePoints) {
  if (codePoints.length < 2 || !codePoints.contains(0x20E3)) return false;
  final first = codePoints.first;
  final validFirst =
      first >= 0x0030 && first <= 0x0039 || first == 0x0023 || first == 0x002A;

  return validFirst &&
      codePoints.every(
        (value) => value == first || value == 0xFE0F || value == 0x20E3,
      );
}

bool esEmojiReaccion(String value) {
  final emoji = value.trim();
  if (emoji.isEmpty || emoji.length > 32) return false;

  final segments = emoji.characters.toList(growable: false);
  if (segments.length != 1 || segments.first != emoji) return false;

  final codePoints = emoji.runes.toList(growable: false);
  final hasEmojiBase = codePoints.any(_isEmojiBaseCodePoint);
  final isKeycap = _isKeycapEmojiSequence(codePoints);

  return (hasEmojiBase || isKeycap) &&
      codePoints.every(_isEmojiSequenceCodePoint);
}

String normalizarEmojiReaccion(String emoji) {
  final trimmed = emoji.trim();
  if (trimmed.isEmpty) return '';
  final first = trimmed.characters.first;
  return esEmojiReaccion(first) ? first : '';
}

Map<String, bool> resolvedNotificationSettings(Map<String, dynamic>? userData) {
  final rawSettings = userData?['notificationSettings'];
  final settings = <String, bool>{...kDefaultNotificationSettings};

  if (rawSettings is Map) {
    for (final entry in kDefaultNotificationSettings.entries) {
      final value = rawSettings[entry.key];
      if (value is bool) {
        settings[entry.key] = value;
      }
    }
  }

  return settings;
}

bool notificationGlobalEnabledFromData(Map<String, dynamic>? userData) {
  return resolvedNotificationSettings(userData)['globalEnabled'] ?? true;
}

bool foregroundDeliveryOptionEnabled(RemoteMessage message, String key) {
  return message.data[key]?.toString() != 'false';
}

Map<String, String> foregroundNotificationPayload(RemoteMessage message) {
  final payload = <String, String>{};

  message.data.forEach((key, value) {
    payload[key] = value?.toString() ?? '';
  });

  final messageId = message.messageId;
  if (messageId != null && messageId.isNotEmpty) {
    payload['messageId'] = messageId;
  }

  return payload;
}

RemoteMessage? remoteMessageFromForegroundPayload(String payload) {
  try {
    final decoded = jsonDecode(payload);
    if (decoded is! Map) return null;

    final data = <String, dynamic>{};
    String? messageId;

    decoded.forEach((key, value) {
      final stringKey = key.toString();
      final stringValue = value?.toString() ?? '';

      if (stringKey == 'messageId') {
        messageId = stringValue.isEmpty ? null : stringValue;
      } else {
        data[stringKey] = stringValue;
      }
    });

    return RemoteMessage(data: data, messageId: messageId);
  } catch (error) {
    logDebug('No se pudo leer la notificación foreground: $error');
    return null;
  }
}

Future<void> mostrarNotificacionForegroundAndroid(RemoteMessage message) async {
  if (!Platform.isAndroid) return;
  final type = message.data['type']?.toString();
  if (!kForegroundLocalNotificationTypes.contains(type)) return;

  final title = message.notification?.title?.trim();
  final body = message.notification?.body?.trim();

  if ((title == null || title.isEmpty) && (body == null || body.isEmpty)) {
    return;
  }

  try {
    await foregroundNotificationChannel.invokeMethod<void>('show', {
      'title': title == null || title.isEmpty ? 'Sunday Selfie' : title,
      'body': body ?? '',
      'payload': jsonEncode(foregroundNotificationPayload(message)),
      'messageId': message.messageId ?? '',
      'soundEnabled': foregroundDeliveryOptionEnabled(message, 'soundEnabled'),
      'vibrationEnabled': foregroundDeliveryOptionEnabled(
        message,
        'vibrationEnabled',
      ),
    });
  } catch (error) {
    logDebug('No se pudo mostrar la notificación foreground: $error');
  }
}

Future<void> actualizarEstadoTokensNotificacion({
  required User user,
  required bool enabled,
}) async {
  final firestore = FirebaseFirestore.instance;
  final tokensSnapshot = await firestore
      .collection('users')
      .doc(user.uid)
      .collection('notificationTokens')
      .get();

  if (tokensSnapshot.docs.isEmpty) return;

  final batch = firestore.batch();

  for (final tokenDoc in tokensSnapshot.docs) {
    batch.update(tokenDoc.reference, {
      'enabled': enabled,
      'lastSeenAt': FieldValue.serverTimestamp(),
    });
  }

  await batch.commit();
}

Future<void> guardarTokenNotificaciones({
  required User user,
  required String token,
}) async {
  if (token.trim().isEmpty) return;

  final firestore = FirebaseFirestore.instance;
  final tokenId = crearNotificationTokenId(token);
  final userDoc = await firestore.collection('users').doc(user.uid).get();
  final tokenEnabled = notificationGlobalEnabledFromData(userDoc.data());

  final tokenRef = firestore
      .collection('users')
      .doc(user.uid)
      .collection('notificationTokens')
      .doc(tokenId);

  await firestore.runTransaction((transaction) async {
    final tokenDoc = await transaction.get(tokenRef);

    final data = {
      'token': token,
      'tokenId': tokenId,
      'platform': obtenerPlatformActual(),
      'enabled': tokenEnabled,
      'lastSeenAt': FieldValue.serverTimestamp(),
    };

    if (tokenDoc.exists) {
      transaction.update(tokenRef, data);
    } else {
      transaction.set(tokenRef, {
        ...data,
        'createdAt': FieldValue.serverTimestamp(),
      });
    }
  });
}

Future<void> registrarTokenNotificaciones(User user) async {
  try {
    final messaging = FirebaseMessaging.instance;

    final settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );

    final autorizado =
        settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;

    if (!autorizado) {
      logDebug('Notificaciones no autorizadas por el usuario.');
      return;
    }

    if (Platform.isIOS || Platform.isMacOS) {
      await messaging.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );
    }

    await messaging.setAutoInitEnabled(true);

    final token = await messaging.getToken();

    if (token != null && token.isNotEmpty) {
      await guardarTokenNotificaciones(user: user, token: token);
    }

    FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
      await guardarTokenNotificaciones(user: user, token: newToken);
    });
  } catch (error) {
    logDebug('No se pudo registrar el token FCM: $error');
  }
}

class CreatedGroupInfo {
  final String groupId;
  final String inviteCode;

  const CreatedGroupInfo({required this.groupId, required this.inviteCode});
}

Future<CreatedGroupInfo> crearGrupoMinimo({
  required String nombreGrupo,
  XFile? groupPhoto,
  String? groupEmoji,
  int? groupColorValue,
}) async {
  final currentUser = FirebaseAuth.instance.currentUser;
  if (currentUser == null) {
    throw Exception('No hay usuario autenticado');
  }

  final firestore = FirebaseFirestore.instance;
  final cleanEmoji = groupEmoji?.trim();
  final resolvedEmoji = cleanEmoji == null || cleanEmoji.isEmpty
      ? null
      : cleanEmoji;
  final resolvedColorValue =
      groupColorValue ?? kGroupColorOptions.first.toARGB32();

  late String groupId;
  late String inviteCode;

  try {
    final callable = FirebaseFunctions.instance.httpsCallable('crearGrupo');
    final result = await callable.call<dynamic>({
      'name': nombreGrupo,
      'emoji': resolvedEmoji,
      'colorValue': resolvedColorValue,
    });
    final resultData = result.data;

    if (resultData is! Map) {
      throw Exception('Firebase no devolvió los datos del grupo');
    }

    groupId = (resultData['groupId'] ?? '').toString().trim();
    inviteCode = (resultData['inviteCode'] ?? '').toString().trim();

    if (groupId.isEmpty || inviteCode.isEmpty) {
      throw Exception('Firebase no devolvió una invitación válida');
    }
  } on FirebaseFunctionsException catch (error) {
    throw Exception(error.message ?? 'No se pudo crear el grupo');
  }

  if (groupPhoto != null) {
    try {
      final photoUrl = await actualizarFotoGrupo(
        groupId: groupId,
        foto: groupPhoto,
        markActivity: false,
      );

      final userGroupRef = firestore
          .collection('users')
          .doc(currentUser.uid)
          .collection('groups')
          .doc(groupId);

      await userGroupRef.set({
        'groupPhotoUrlSnapshot': photoUrl,
        'lastActivityAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (error) {
      logDebug('Grupo creado sin foto porque falló la subida: $error');
    }
  }

  return CreatedGroupInfo(groupId: groupId, inviteCode: inviteCode);
}

String crearEnlaceInvitacion(String inviteCode) {
  final code = inviteCode.trim();
  return code.isEmpty
      ? 'https://sundayselfie.app'
      : 'https://sundayselfie.app/j/$code';
}

String normalizarCodigoInvitacion(String value) {
  final clean = value.trim();
  if (clean.toUpperCase().startsWith('TEMP-')) {
    return 'TEMP-${clean.substring(5)}';
  }
  return clean.toUpperCase();
}

String normalizarEntradaInvitacion(String entrada) {
  var value = entrada.trim();

  if (value.isEmpty) return '';

  value = value.replaceAll('\n', '').replaceAll('\t', '').trim();

  final uri = Uri.tryParse(value);
  final queryCode =
      uri?.queryParameters['code'] ?? uri?.queryParameters['invite'];
  if (queryCode != null && queryCode.trim().isNotEmpty) {
    return normalizarCodigoInvitacion(queryCode);
  }

  final joinMatch = RegExp(
    r'(?:^|/)(j|join|invite)/([^/?#\s]+)',
    caseSensitive: false,
  ).firstMatch(value);
  if (joinMatch != null) {
    return normalizarCodigoInvitacion(
      Uri.decodeComponent(joinMatch.group(2) ?? ''),
    );
  }

  final tempMatch = RegExp(
    r'TEMP-[A-Za-z0-9_-]+',
    caseSensitive: false,
  ).firstMatch(value);
  if (tempMatch != null) {
    return normalizarCodigoInvitacion(tempMatch.group(0)!);
  }

  return normalizarCodigoInvitacion(value);
}

String? obtenerInvitacionDesdeDeepLink(Uri uri) {
  final host = uri.host.toLowerCase();
  final isSundaySelfieDomain =
      host == 'sundayselfie.app' || host == 'www.sundayselfie.app';

  if (!isSundaySelfieDomain) return null;

  final pathSegments = uri.pathSegments;
  final hasInvitePath =
      pathSegments.length >= 2 &&
      ['j', 'join', 'invite'].contains(pathSegments.first.toLowerCase());

  if (!hasInvitePath) return null;

  final invitation = normalizarEntradaInvitacion(uri.toString());
  return invitation.isEmpty ? null : invitation;
}

String? obtenerGroupIdDesdeCodigo(String codigo) {
  final normalizado = normalizarEntradaInvitacion(codigo);
  const prefijo = 'TEMP-';

  if (!normalizado.toUpperCase().startsWith(prefijo)) {
    return null;
  }

  final groupId = normalizado.substring(prefijo.length).trim();

  if (groupId.isEmpty) {
    return null;
  }

  return groupId;
}

Future<String?> resolverGroupIdDesdeInvitacion(String codigo) async {
  final legacyGroupId = obtenerGroupIdDesdeCodigo(codigo);
  if (legacyGroupId != null) return legacyGroupId;

  final inviteCode = normalizarEntradaInvitacion(codigo);
  if (inviteCode.isEmpty || inviteCode.contains('/')) return null;

  try {
    final inviteDoc = await FirebaseFirestore.instance
        .collection('inviteCodes')
        .doc(inviteCode)
        .get();
    final inviteData = inviteDoc.data();

    if (!inviteDoc.exists || inviteData?['active'] != true) return null;

    final groupId = inviteData?['groupId'];
    if (groupId is String && groupId.trim().isNotEmpty) {
      return groupId.trim();
    }
  } catch (error) {
    logDebug('No se pudo resolver la invitación: $error');
  }

  return null;
}

int calcularNumeroSemanaISO(DateTime fecha) {
  final jueves = fecha.add(Duration(days: 3 - ((fecha.weekday + 6) % 7)));
  final primerJueves = DateTime(jueves.year, 1, 4);

  return 1 +
      ((jueves.difference(primerJueves).inDays -
                  3 +
                  ((primerJueves.weekday + 6) % 7)) /
              7)
          .floor();
}

int calcularAnioISO(DateTime fecha) {
  final jueves = fecha.add(Duration(days: 3 - ((fecha.weekday + 6) % 7)));
  return jueves.year;
}

String obtenerWeekKeyActual({DateTime? now}) {
  final ahora = now ?? DateTime.now();
  final isoYear = calcularAnioISO(ahora);
  final isoWeek = calcularNumeroSemanaISO(ahora).toString().padLeft(2, '0');

  return '$isoYear-W$isoWeek';
}

String obtenerWeekKeyDesdeFecha(DateTime fecha) {
  final isoYear = calcularAnioISO(fecha);
  final isoWeek = calcularNumeroSemanaISO(fecha).toString().padLeft(2, '0');

  return '$isoYear-W$isoWeek';
}

String obtenerEtiquetaSemana(String weekKey) {
  final parts = weekKey.split('-W');
  if (parts.length != 2) return weekKey;
  return 'Semana ${parts[1]} / ${parts[0]}';
}

String obtenerEtiquetaSemanaCorta(String weekKey) {
  final parts = weekKey.split('-W');
  if (parts.length != 2) return weekKey;
  return 'Semana ${parts[1]}';
}

List<String> construirItemsSelectorSemanas(Iterable<String> weekKeys) {
  final items = <String>[];
  String? previousYear;

  for (final key in weekKeys) {
    final parts = key.split('-W');
    final year = parts.isNotEmpty ? parts.first : '';
    if (previousYear != null && year.isNotEmpty && year != previousYear) {
      items.add('year:$year');
    }
    items.add('week:$key');
    previousYear = year;
  }

  return items;
}

bool esDomingo({DateTime? now}) {
  return (now ?? DateTime.now()).weekday == DateTime.sunday;
}

bool debeMostrarMiembroSinPublicar({required bool posted, DateTime? now}) {
  return !posted && esDomingo(now: now);
}

bool esLunes({DateTime? now}) {
  return (now ?? DateTime.now()).weekday == DateTime.monday;
}

String obtenerWeekKeyDomingoAnterior({DateTime? now}) {
  return obtenerWeekKeyAnterior(obtenerWeekKeyActual(now: now));
}

bool puedeSubirSelfieLunesConRetraso(String weekKey, {DateTime? now}) {
  final current = now ?? DateTime.now();
  return esLunes(now: current) &&
      weekKey == obtenerWeekKeyDomingoAnterior(now: current);
}

bool sundaySelfieSiguePendiente(String weekKey, {DateTime? now}) {
  final current = now ?? DateTime.now();
  final isCurrentSunday =
      esDomingo(now: current) && weekKey == obtenerWeekKeyActual(now: current);

  return isCurrentSunday ||
      puedeSubirSelfieLunesConRetraso(weekKey, now: current);
}

String missingSundaySelfieStatusLabel(String weekKey, {DateTime? now}) {
  return sundaySelfieSiguePendiente(weekKey, now: now)
      ? 'Sunday Selfie pendiente'
      : 'Sunday Selfie no publicado';
}

DateTime cierreDomingoAnterior({DateTime? now}) {
  final current = now ?? DateTime.now();
  final today = DateTime(current.year, current.month, current.day);
  return today.subtract(const Duration(milliseconds: 1));
}

bool miembroPuedeSubirSelfieLunesConRetraso(
  String weekKey,
  dynamic joinedAt, {
  DateTime? now,
}) {
  if (!puedeSubirSelfieLunesConRetraso(weekKey, now: now)) return false;

  final joined = timestampToDate(joinedAt);
  if (joined == null) return false;

  return !joined.isAfter(cierreDomingoAnterior(now: now));
}

int diasHastaDomingo() {
  final weekday = DateTime.now().weekday;
  if (weekday == DateTime.sunday) return 0;
  return DateTime.sunday - weekday;
}

int? _weekKeyOrderValue(String weekKey) {
  final parts = weekKey.split('-W');
  if (parts.length != 2) return null;

  final isoYear = int.tryParse(parts[0]);
  final isoWeek = int.tryParse(parts[1]);
  if (isoYear == null || isoWeek == null) return null;

  return isoYear * 100 + isoWeek;
}

List<String> obtenerWeekKeysDomingosVisibles(
  Iterable<String> weekKeys, {
  DateTime? now,
}) {
  final current = now ?? DateTime.now();
  final currentWeekKey = obtenerWeekKeyActual(now: current);
  final currentWeekOrder = _weekKeyOrderValue(currentWeekKey);
  final includeCurrentSunday = esDomingo(now: current);
  final visibleWeekKeys = <String>{};

  visibleWeekKeys.add(obtenerWeekKeyVisibleMasReciente(now: current));

  for (final rawWeekKey in weekKeys) {
    final weekKey = rawWeekKey.trim();
    if (weekKey.isEmpty) continue;

    final weekOrder = _weekKeyOrderValue(weekKey);
    if (weekOrder != null && currentWeekOrder != null) {
      if (weekOrder > currentWeekOrder) continue;
      if (!includeCurrentSunday && weekOrder == currentWeekOrder) continue;
    } else if (!includeCurrentSunday && weekKey == currentWeekKey) {
      continue;
    }

    visibleWeekKeys.add(weekKey);
  }

  return visibleWeekKeys.toList();
}

enum SundayWindowPhase { waiting, open, closed }

class SundayWindowState {
  final String weekKey;
  final DateTime openAt;
  final DateTime closeAt;
  final SundayWindowPhase phase;

  const SundayWindowState({
    required this.weekKey,
    required this.openAt,
    required this.closeAt,
    required this.phase,
  });

  bool get canUpload => phase == SundayWindowPhase.open;

  String get phaseLabel {
    switch (phase) {
      case SundayWindowPhase.waiting:
        return 'Esperando al domingo';
      case SundayWindowPhase.open:
        return 'Ventana abierta';
      case SundayWindowPhase.closed:
        return 'Ventana cerrada';
    }
  }

  String get actionLabel {
    switch (phase) {
      case SundayWindowPhase.waiting:
        return 'La próxima ventana se abrirá el domingo';
      case SundayWindowPhase.open:
        return 'Puedes publicar tu selfie semanal';
      case SundayWindowPhase.closed:
        return 'La ventana de subida ya ha cerrado';
    }
  }

  String get shortLabel {
    switch (phase) {
      case SundayWindowPhase.waiting:
        return 'Abre el domingo a las ${formatWindowTime(openAt)}';
      case SundayWindowPhase.open:
        return 'Abierta hasta las ${formatWindowTime(closeAt)}';
      case SundayWindowPhase.closed:
        return 'Cerrada hasta el próximo domingo';
    }
  }
}

SundayWindowState obtenerSundayWindowState({DateTime? now}) {
  final current = now ?? DateTime.now();
  final today = DateTime(current.year, current.month, current.day);

  final daysToSunday = current.weekday == DateTime.sunday
      ? 0
      : DateTime.sunday - current.weekday;
  final sunday = today.add(Duration(days: daysToSunday));

  final openAt = DateTime(sunday.year, sunday.month, sunday.day, 0, 0);
  final closeAt = DateTime(
    sunday.year,
    sunday.month,
    sunday.day,
    23,
    59,
    59,
    999,
  );
  final weekKey = obtenerWeekKeyActual(now: current);

  SundayWindowPhase phase;

  if (current.isBefore(openAt)) {
    phase = SundayWindowPhase.waiting;
  } else if (current.isBefore(closeAt)) {
    phase = SundayWindowPhase.open;
  } else {
    phase = SundayWindowPhase.closed;
  }

  return SundayWindowState(
    weekKey: weekKey,
    openAt: openAt,
    closeAt: closeAt,
    phase: phase,
  );
}

String formatWindowTime(DateTime date) {
  return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
}

DateTime obtenerObjetivoCountdown(SundayWindowState window) {
  if (window.phase == SundayWindowPhase.open) {
    return window.closeAt;
  }

  if (window.phase == SundayWindowPhase.closed) {
    return window.openAt.add(const Duration(days: 7));
  }

  return window.openAt;
}

Duration obtenerTiempoRestanteVentana(
  SundayWindowState window, {
  DateTime? now,
}) {
  final current = now ?? DateTime.now();
  final target = obtenerObjetivoCountdown(window);
  final remaining = target.difference(current);

  if (remaining.isNegative) {
    return Duration.zero;
  }

  return remaining;
}

String formatCountdown(Duration duration) {
  final days = duration.inDays;
  final hours = duration.inHours.remainder(24);
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);

  if (days > 0) {
    return '${days}d ${hours.toString().padLeft(2, '0')}h';
  }

  if (hours > 0) {
    return '${hours}h ${minutes.toString().padLeft(2, '0')}m';
  }

  return '${minutes.toString().padLeft(2, '0')}m ${seconds.toString().padLeft(2, '0')}s';
}

String obtenerTituloCountdown(SundayWindowState window) {
  switch (window.phase) {
    case SundayWindowPhase.waiting:
      return 'Falta para publicar';
    case SundayWindowPhase.open:
      return 'Tiempo restante';
    case SundayWindowPhase.closed:
      return 'Próxima ventana';
  }
}

String obtenerSubtituloCountdown(SundayWindowState window) {
  switch (window.phase) {
    case SundayWindowPhase.waiting:
      return 'La subida se abrirá el domingo a las ${formatWindowTime(window.openAt)}';
    case SundayWindowPhase.open:
      return 'Puedes publicar hasta las ${formatWindowTime(window.closeAt)}';
    case SundayWindowPhase.closed:
      return 'La subida volverá a abrirse el próximo domingo a las ${formatWindowTime(window.openAt)}';
  }
}

int comparableTimestampMillis(dynamic value) {
  if (value is Timestamp) return value.toDate().millisecondsSinceEpoch;
  if (value is DateTime) return value.millisecondsSinceEpoch;
  if (value is int) return value;
  return 0;
}

int intFromValue(dynamic value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse('$value') ?? fallback;
}

int semanasActivasDesdeCreatedAt(dynamic createdAt) {
  DateTime? created;

  if (createdAt is Timestamp) {
    created = createdAt.toDate();
  } else if (createdAt is DateTime) {
    created = createdAt;
  }

  if (created == null) return 1;

  final now = DateTime.now();
  final firstSunday = DateTime(created.year, created.month, created.day).add(
    Duration(
      days: created.weekday == DateTime.sunday
          ? 7
          : DateTime.sunday - created.weekday,
    ),
  );

  if (firstSunday.isAfter(now)) return 1;

  return (now.difference(firstSunday).inDays ~/ 7 + 1).clamp(1, 999).toInt();
}

DateTime lunesDeSemanaISO(int isoYear, int isoWeek) {
  final fourthOfJanuary = DateTime(isoYear, 1, 4);
  final firstIsoMonday = fourthOfJanuary.subtract(
    Duration(days: fourthOfJanuary.weekday - DateTime.monday),
  );
  return firstIsoMonday.add(Duration(days: (isoWeek - 1) * 7));
}

DateTime? lunesDesdeWeekKey(String weekKey) {
  final parts = weekKey.split('-W');
  if (parts.length != 2) return null;

  final isoYear = int.tryParse(parts[0]);
  final isoWeek = int.tryParse(parts[1]);
  if (isoYear == null || isoWeek == null) return null;

  return lunesDeSemanaISO(isoYear, isoWeek);
}

DateTime? domingoDesdeWeekKey(String weekKey) {
  final monday = lunesDesdeWeekKey(weekKey);
  if (monday == null) return null;

  return monday.add(const Duration(days: 6));
}

String obtenerWeekKeyAnterior(String weekKey) {
  final parts = weekKey.split('-W');
  if (parts.length != 2) return weekKey;

  final isoYear = int.tryParse(parts[0]);
  final isoWeek = int.tryParse(parts[1]);
  if (isoYear == null || isoWeek == null) return weekKey;

  final previousMonday = lunesDeSemanaISO(
    isoYear,
    isoWeek,
  ).subtract(const Duration(days: 7));
  final previousYear = calcularAnioISO(previousMonday);
  final previousWeek = calcularNumeroSemanaISO(
    previousMonday,
  ).toString().padLeft(2, '0');

  return '$previousYear-W$previousWeek';
}

String obtenerWeekKeySiguiente(String weekKey) {
  final monday = lunesDesdeWeekKey(weekKey);
  if (monday == null) return weekKey;

  return obtenerWeekKeyDesdeFecha(monday.add(const Duration(days: 7)));
}

String obtenerWeekKeyVisibleMasReciente({DateTime? now}) {
  final current = now ?? DateTime.now();
  final currentWeekKey = obtenerWeekKeyActual(now: current);

  if (esDomingo(now: current)) return currentWeekKey;

  return obtenerWeekKeyAnterior(currentWeekKey);
}

String obtenerWeekKeyInicioRachaPublicacion({DateTime? now}) {
  return obtenerWeekKeyVisibleMasReciente(now: now);
}

String resolverWeekKeySeleccionadaGrupo({
  required Iterable<String> weekKeys,
  required String selectedWeekKey,
  DateTime? now,
}) {
  final availableWeekKeys = weekKeys.toList(growable: false);
  if (availableWeekKeys.isEmpty) return '';

  final cleanSelectedWeekKey = selectedWeekKey.trim();
  if (cleanSelectedWeekKey.isNotEmpty &&
      availableWeekKeys.contains(cleanSelectedWeekKey)) {
    return cleanSelectedWeekKey;
  }

  final latestVisibleWeekKey = obtenerWeekKeyVisibleMasReciente(now: now);
  if (availableWeekKeys.contains(latestVisibleWeekKey)) {
    return latestVisibleWeekKey;
  }

  return availableWeekKeys.first;
}

List<String> ordenarWeekKeysDescendentes(Iterable<String> weekKeys) {
  final uniqueWeekKeys = weekKeys
      .map((weekKey) => weekKey.trim())
      .where((weekKey) => weekKey.isNotEmpty)
      .toSet()
      .toList();

  uniqueWeekKeys.sort((a, b) {
    final aOrder = _weekKeyOrderValue(a) ?? 0;
    final bOrder = _weekKeyOrderValue(b) ?? 0;
    return bOrder.compareTo(aOrder);
  });

  return uniqueWeekKeys;
}

List<String> obtenerWeekKeysCalendarioGrupo({
  required dynamic groupCreatedAt,
  required Iterable<String> existingWeekKeys,
  DateTime? now,
}) {
  final current = now ?? DateTime.now();
  final created = timestampToDate(groupCreatedAt);

  if (created == null) {
    return ordenarWeekKeysDescendentes(
      obtenerWeekKeysDomingosVisibles(existingWeekKeys, now: current),
    );
  }

  final firstWeekKey = obtenerWeekKeyDesdeFecha(created);
  final latestWeekKey = obtenerWeekKeyVisibleMasReciente(now: current);
  final firstMonday = lunesDesdeWeekKey(firstWeekKey);
  final latestMonday = lunesDesdeWeekKey(latestWeekKey);

  if (firstMonday == null || latestMonday == null) {
    return ordenarWeekKeysDescendentes(
      obtenerWeekKeysDomingosVisibles(existingWeekKeys, now: current),
    );
  }

  if (firstMonday.isAfter(latestMonday)) return const [];

  final weekKeys = <String>[];
  var cursor = firstMonday;

  while (!cursor.isAfter(latestMonday) && weekKeys.length < 9999) {
    weekKeys.add(obtenerWeekKeyDesdeFecha(cursor));
    cursor = cursor.add(const Duration(days: 7));
  }

  return weekKeys.reversed.toList();
}

Future<int> calcularRachaPublicacionUsuarioEnGrupo({
  required String groupId,
  required String uid,
  int maxWeeks = 104,
  DateTime? now,
}) async {
  final firestore = FirebaseFirestore.instance;
  var weekKey = obtenerWeekKeyInicioRachaPublicacion(now: now);
  var streak = 0;

  for (var i = 0; i < maxWeeks; i += 1) {
    final postDoc = await firestore
        .collection('groups')
        .doc(groupId)
        .collection('weeks')
        .doc(weekKey)
        .collection('posts')
        .doc(uid)
        .get();

    if (!postDoc.exists) {
      break;
    }

    streak += 1;
    weekKey = obtenerWeekKeyAnterior(weekKey);
  }

  return streak;
}

class GroupStreakStats {
  final int current;
  final int record;

  const GroupStreakStats({required this.current, required this.record});

  static const zero = GroupStreakStats(current: 0, record: 0);
}

GroupStreakStats calcularEstadisticasRachaCompletaGrupo({
  required Iterable<String> weekKeys,
  required Map<String, int> postCountsByWeek,
  required int memberCount,
}) {
  if (memberCount <= 0) return GroupStreakStats.zero;

  final orderedWeekKeys = ordenarWeekKeysDescendentes(weekKeys);
  if (orderedWeekKeys.isEmpty) return GroupStreakStats.zero;

  var current = 0;
  var currentOpen = true;
  var running = 0;
  var record = 0;

  for (final weekKey in orderedWeekKeys) {
    final complete = (postCountsByWeek[weekKey] ?? 0) >= memberCount;

    if (complete) {
      running += 1;
      if (currentOpen) current += 1;
      if (running > record) record = running;
    } else {
      running = 0;
      currentOpen = false;
    }
  }

  return GroupStreakStats(current: current, record: record);
}

Future<GroupStreakStats> calcularEstadisticasRachaCompletaGrupoFirestore({
  required String groupId,
  DateTime? now,
}) async {
  final firestore = FirebaseFirestore.instance;
  final groupDoc = await firestore.collection('groups').doc(groupId).get();
  final groupData = groupDoc.data();

  if (!groupDoc.exists || groupData == null || groupData['deleted'] == true) {
    return GroupStreakStats.zero;
  }

  final memberCount = intFromValue(groupData['memberCount']);
  final weeksSnapshot = await firestore
      .collection('groups')
      .doc(groupId)
      .collection('weeks')
      .get();
  final postCountsByWeek = {
    for (final doc in weeksSnapshot.docs)
      doc.id: intFromValue(doc.data()['postCount']),
  };
  final weekKeys = obtenerWeekKeysCalendarioGrupo(
    groupCreatedAt: groupData['createdAt'],
    existingWeekKeys: weeksSnapshot.docs.map((doc) => doc.id),
    now: now,
  );

  return calcularEstadisticasRachaCompletaGrupo(
    weekKeys: weekKeys,
    postCountsByWeek: postCountsByWeek,
    memberCount: memberCount,
  );
}

Future<void> solicitarEntradaAGrupo({
  required String groupId,
  String? inviteInput,
}) async {
  final inviteCodeUsed = normalizarEntradaInvitacion(inviteInput ?? '');

  if (inviteCodeUsed.isEmpty) {
    throw Exception('Invitación no válida');
  }

  try {
    await FirebaseFunctions.instance
        .httpsCallable('solicitarEntradaGrupo')
        .call<void>({'groupId': groupId, 'inviteCodeUsed': inviteCodeUsed});
  } on FirebaseFunctionsException catch (error) {
    throw Exception(error.message ?? 'No se pudo enviar la solicitud');
  }
}

Future<void> aceptarSolicitudEntrada({
  required String groupId,
  required String requestUid,
}) async {
  try {
    final callable = FirebaseFunctions.instance.httpsCallable(
      'aceptarSolicitud',
    );

    await callable.call<void>({'groupId': groupId, 'requestUid': requestUid});
  } on FirebaseFunctionsException catch (error) {
    throw Exception(error.message ?? 'No se pudo aceptar la solicitud');
  }
}

Future<void> rechazarSolicitudEntrada({
  required String groupId,
  required String requestUid,
}) async {
  try {
    final callable = FirebaseFunctions.instance.httpsCallable(
      'rechazarSolicitud',
    );

    await callable.call<void>({'groupId': groupId, 'requestUid': requestUid});
  } on FirebaseFunctionsException catch (error) {
    throw Exception(error.message ?? 'No se pudo rechazar la solicitud');
  }
}

Future<void> hacerAdministradorMiembro({
  required String groupId,
  required String targetUid,
}) async {
  try {
    final callable = FirebaseFunctions.instance.httpsCallable(
      'promoverAdministrador',
    );

    await callable.call<void>({'groupId': groupId, 'targetUid': targetUid});
  } on FirebaseFunctionsException catch (error) {
    throw Exception(error.message ?? 'No se pudo hacer administrador');
  }
}

Future<void> expulsarMiembroGrupo({
  required String groupId,
  required String targetUid,
}) async {
  try {
    final callable = FirebaseFunctions.instance.httpsCallable(
      'expulsarMiembro',
    );

    await callable.call<void>({'groupId': groupId, 'targetUid': targetUid});
  } on FirebaseFunctionsException catch (error) {
    throw Exception(error.message ?? 'No se pudo expulsar al miembro');
  }
}

Future<void> permitirReingresoGrupo({
  required String groupId,
  required String targetUid,
}) async {
  try {
    final callable = FirebaseFunctions.instance.httpsCallable(
      'permitirReingreso',
    );

    await callable.call<void>({'groupId': groupId, 'targetUid': targetUid});
  } on FirebaseFunctionsException catch (error) {
    throw Exception(error.message ?? 'No se pudo permitir el reingreso');
  }
}

Future<void> actualizarNombreGrupo({
  required String groupId,
  required String newName,
}) async {
  final currentUser = FirebaseAuth.instance.currentUser;
  if (currentUser == null) {
    throw Exception('No hay usuario autenticado');
  }

  final trimmedName = newName.trim();
  if (trimmedName.isEmpty) {
    throw Exception('El nombre del grupo no puede estar vacío');
  }

  final firestore = FirebaseFirestore.instance;
  final groupRef = firestore.collection('groups').doc(groupId);
  final currentMemberRef = groupRef.collection('members').doc(currentUser.uid);

  await firestore.runTransaction((transaction) async {
    final currentMemberDoc = await transaction.get(currentMemberRef);
    if (currentMemberDoc.data()?['role'] != 'admin') {
      throw Exception(
        'Solo un administrador puede cambiar el nombre del grupo',
      );
    }

    transaction.update(groupRef, {
      'name': trimmedName,
      'updatedAt': FieldValue.serverTimestamp(),
      'lastActivityAt': FieldValue.serverTimestamp(),
    });
  });

  try {
    final membersSnapshot = await groupRef.collection('members').get();
    WriteBatch batch = firestore.batch();
    var batchCount = 0;

    Future<void> commitIfNeeded({bool force = false}) async {
      if (batchCount == 0) return;
      if (!force && batchCount < 430) return;
      await batch.commit();
      batch = firestore.batch();
      batchCount = 0;
    }

    for (final memberDoc in membersSnapshot.docs) {
      final userGroupRef = firestore
          .collection('users')
          .doc(memberDoc.id)
          .collection('groups')
          .doc(groupId);

      batch.set(userGroupRef, {
        'displayNameSnapshot': trimmedName,
        'lastActivityAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      batchCount += 1;
      await commitIfNeeded();
    }

    await commitIfNeeded(force: true);
  } catch (error) {
    logDebug('No se pudo propagar el nombre del grupo: $error');
  }
}

Future<void> actualizarNombreEnGrupo({
  required String groupId,
  required String newName,
}) async {
  final currentUser = FirebaseAuth.instance.currentUser;
  if (currentUser == null) {
    throw Exception('No hay usuario autenticado');
  }

  final trimmedName = newName.trim();
  if (trimmedName.isEmpty) {
    throw Exception('El nombre no puede estar vacío');
  }

  if (trimmedName.characters.length > 80) {
    throw Exception('El nombre no puede superar 80 caracteres');
  }

  final memberRef = FirebaseFirestore.instance
      .collection('groups')
      .doc(groupId)
      .collection('members')
      .doc(currentUser.uid);
  final memberDoc = await memberRef.get();

  if (!memberDoc.exists) {
    throw Exception('No perteneces a este grupo');
  }

  await memberRef.set({
    'effectiveName': trimmedName,
    'groupNameOverride': trimmedName,
    'profileSyncedAt': FieldValue.serverTimestamp(),
  }, SetOptions(merge: true));
}

Future<String> actualizarFotoGrupo({
  required String groupId,
  required XFile foto,
  bool markActivity = true,
}) async {
  final currentUser = FirebaseAuth.instance.currentUser;
  if (currentUser == null) {
    throw Exception('No hay usuario autenticado');
  }

  final firestore = FirebaseFirestore.instance;
  final groupRef = firestore.collection('groups').doc(groupId);
  final memberRef = groupRef.collection('members').doc(currentUser.uid);
  final memberDoc = await memberRef.get();

  if (memberDoc.data()?['role'] != 'admin') {
    throw Exception(
      'Solo los administradores pueden cambiar la foto del grupo',
    );
  }

  final timestamp = DateTime.now().millisecondsSinceEpoch;
  final storagePath = 'groups/$groupId/profile/group_$timestamp.jpg';
  final storageRef = FirebaseStorage.instance.ref().child(storagePath);

  await storageRef.putFile(
    File(foto.path),
    SettableMetadata(
      contentType: 'image/jpeg',
      customMetadata: {
        'groupId': groupId,
        'uid': currentUser.uid,
        'kind': 'groupPhoto',
      },
    ),
  );

  final downloadUrl = await storageRef.getDownloadURL();

  await groupRef.update({
    'photoUrl': downloadUrl,
    'photoStoragePath': storagePath,
    'updatedAt': FieldValue.serverTimestamp(),
    'lastActivityAt': FieldValue.serverTimestamp(),
  });

  try {
    final membersSnapshot = await groupRef.collection('members').get();
    WriteBatch batch = firestore.batch();
    var batchCount = 0;

    Future<void> commitIfNeeded({bool force = false}) async {
      if (batchCount == 0) return;
      if (!force && batchCount < 430) return;
      await batch.commit();
      batch = firestore.batch();
      batchCount = 0;
    }

    for (final memberDoc in membersSnapshot.docs) {
      final userGroupRef = firestore
          .collection('users')
          .doc(memberDoc.id)
          .collection('groups')
          .doc(groupId);

      batch.set(userGroupRef, {
        'groupPhotoUrlSnapshot': downloadUrl,
        'lastActivityAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      batchCount += 1;
      await commitIfNeeded();
    }

    await commitIfNeeded(force: true);
  } catch (error) {
    logDebug('No se pudo propagar la foto del grupo: $error');
  }

  if (markActivity) {
    await marcarActividadGrupo(groupId: groupId);
  }

  return downloadUrl;
}

Future<void> regenerarInvitacionGrupo({required String groupId}) async {
  try {
    final callable = FirebaseFunctions.instance.httpsCallable(
      'regenerarInvitacion',
    );

    await callable.call<void>({'groupId': groupId});
  } on FirebaseFunctionsException catch (error) {
    throw Exception(error.message ?? 'No se pudo regenerar la invitación');
  }
}

Future<void> abandonarGrupo({required String groupId}) async {
  try {
    final callable = FirebaseFunctions.instance.httpsCallable('abandonarGrupo');

    await callable.call<void>({'groupId': groupId});
  } on FirebaseFunctionsException catch (error) {
    throw Exception(error.message ?? 'No se pudo abandonar el grupo');
  }
}

Future<void> eliminarGrupoDeLaApp({required String groupId}) async {
  final currentUser = FirebaseAuth.instance.currentUser;
  if (currentUser == null) {
    throw Exception('No hay usuario autenticado');
  }

  await FirebaseFirestore.instance
      .collection('users')
      .doc(currentUser.uid)
      .collection('groups')
      .doc(groupId)
      .delete();
}

Future<void> publicarSelfieReal({
  required String groupId,
  required User user,
  required XFile foto,
  String? weekKey,
  bool rewardedAdWatched = false,
}) async {
  final currentWeekKey = obtenerWeekKeyActual();
  final targetWeekKey = weekKey ?? currentWeekKey;
  final window = obtenerSundayWindowState();
  final isRegularSundayUpload =
      targetWeekKey == currentWeekKey && window.canUpload;
  final isLateMondayUpload =
      rewardedAdWatched && puedeSubirSelfieLunesConRetraso(targetWeekKey);

  if (!isRegularSundayUpload && !isLateMondayUpload) {
    throw Exception('La ventana de subida está cerrada');
  }

  final firestore = FirebaseFirestore.instance;
  final storage = FirebaseStorage.instance;

  final weekRef = firestore
      .collection('groups')
      .doc(groupId)
      .collection('weeks')
      .doc(targetWeekKey);
  final postRef = weekRef.collection('posts').doc(user.uid);
  final existingPost = await postRef.get();

  if (existingPost.exists) {
    throw Exception('Ya has publicado tu selfie de esta semana');
  }

  await validarFotoSelfie(foto);

  final storagePath = 'groups/$groupId/weeks/$targetWeekKey/${user.uid}.jpg';
  final thumbnailStoragePath =
      'groups/$groupId/weeks/$targetWeekKey/thumbs/${user.uid}.jpg';
  final storageRef = storage.ref().child(storagePath);
  final thumbnailStorageRef = storage.ref().child(thumbnailStoragePath);
  final uploadFile = await _prepararArchivoSelfieParaSubidaTemporal(
    foto: foto,
    groupId: groupId,
    weekKey: targetWeekKey,
    uid: user.uid,
  );

  try {
    await storageRef.putFile(
      uploadFile,
      SettableMetadata(
        contentType: 'image/jpeg',
        customMetadata: {
          'groupId': groupId,
          'weekKey': targetWeekKey,
          'uid': user.uid,
          if (isLateMondayUpload) 'lateUpload': 'true',
          if (isLateMondayUpload) 'rewardedAdWatched': 'true',
        },
      ),
    );
  } on FirebaseException catch (uploadError) {
    try {
      await storageRef.getMetadata();
    } catch (_) {
      logDebug('No se pudo subir la selfie a Storage: $uploadError');
      throw Exception('No se pudo subir la selfie. Inténtalo de nuevo.');
    }
  } finally {
    if (uploadFile.path != foto.path && await uploadFile.exists()) {
      try {
        await uploadFile.delete();
      } catch (error) {
        logDebug('No se pudo borrar la selfie temporal optimizada: $error');
      }
    }
  }

  File? thumbnailFile;
  try {
    thumbnailFile = await crearMiniaturaSelfieTemporal(
      foto: foto,
      groupId: groupId,
      weekKey: targetWeekKey,
      uid: user.uid,
    );
    if (thumbnailFile != null) {
      await thumbnailStorageRef.putFile(
        thumbnailFile,
        SettableMetadata(
          contentType: 'image/jpeg',
          customMetadata: {
            'groupId': groupId,
            'weekKey': targetWeekKey,
            'uid': user.uid,
            'kind': 'selfieThumb',
            if (isLateMondayUpload) 'lateUpload': 'true',
            if (isLateMondayUpload) 'rewardedAdWatched': 'true',
          },
        ),
      );
    }
  } catch (error) {
    logDebug('No se pudo preparar la miniatura de la selfie: $error');
  } finally {
    if (thumbnailFile != null && await thumbnailFile.exists()) {
      try {
        await thumbnailFile.delete();
      } catch (error) {
        logDebug('No se pudo borrar la miniatura temporal: $error');
      }
    }
  }

  try {
    final callable = FirebaseFunctions.instance.httpsCallable(
      'registrarSelfie',
    );

    await callable.call<void>({
      'groupId': groupId,
      if (targetWeekKey != currentWeekKey) 'weekKey': targetWeekKey,
      if (isLateMondayUpload) 'rewardedAdWatched': true,
    });
  } on FirebaseFunctionsException catch (error) {
    throw Exception(error.message ?? 'No se pudo registrar la selfie');
  }
}

Future<void> reaccionarASelfie({
  required String groupId,
  required String weekKey,
  required String postUid,
  required String emoji,
}) async {
  final cleanEmoji = normalizarEmojiReaccion(emoji);
  if (cleanEmoji.isEmpty) {
    throw Exception('Elige una reacción válida');
  }

  try {
    final callable = FirebaseFunctions.instance.httpsCallable(
      'reaccionarASelfie',
    );

    await callable.call<void>({
      'groupId': groupId,
      'weekKey': weekKey,
      'postUid': postUid,
      'emoji': cleanEmoji,
    });
  } on FirebaseFunctionsException catch (error) {
    throw Exception(error.message ?? 'No se pudo guardar la reacción');
  }
}

Future<void> enviarZumbidoSelfie({
  required String groupId,
  required String targetUid,
  bool rewardedAdWatched = false,
}) async {
  try {
    final callable = FirebaseFunctions.instance.httpsCallable(
      'enviarZumbidoSelfie',
    );

    await callable.call<void>({
      'groupId': groupId,
      'targetUid': targetUid,
      if (rewardedAdWatched) 'rewardedAdWatched': true,
    });
  } on FirebaseFunctionsException catch (error) {
    throw Exception(error.message ?? 'No se pudo enviar el zumbido');
  }
}

String? rewardedBuzzAdUnitId() {
  return rewardedAdUnitId();
}

String? rewardedAdUnitId() {
  if (kIsWeb) return null;
  if (Platform.isAndroid) return kRewardedBuzzAdUnitAndroid;
  if (Platform.isIOS) return kRewardedBuzzAdUnitIos;
  return null;
}

Future<bool> confirmarAnuncioZumbidoExtra(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: const Text('Enviar otro zumbido'),
        content: const Text(
          'Cada miembro del grupo solo puede recibir un zumbido por domingo y por grupo. Para poder enviar otro zumbido se debe ver un anuncio.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Salir'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Continuar'),
          ),
        ],
      );
    },
  );

  return confirmed == true;
}

Future<bool> mostrarAnuncioRecompensadoZumbido() async {
  return mostrarAnuncioRecompensado();
}

Future<bool> mostrarAnuncioRecompensado() async {
  final adUnitId = rewardedAdUnitId();
  if (adUnitId == null) {
    throw Exception('Los anuncios no están disponibles en esta plataforma');
  }

  final loadCompleter = Completer<RewardedAd>();
  RewardedAd.load(
    adUnitId: adUnitId,
    request: const AdRequest(),
    rewardedAdLoadCallback: RewardedAdLoadCallback(
      onAdLoaded: (ad) {
        if (!loadCompleter.isCompleted) loadCompleter.complete(ad);
      },
      onAdFailedToLoad: (error) {
        if (!loadCompleter.isCompleted) {
          loadCompleter.completeError(
            Exception('No se pudo cargar el anuncio'),
          );
        }
      },
    ),
  );

  final ad = await loadCompleter.future;
  final rewardCompleter = Completer<bool>();
  var rewardEarned = false;

  ad.fullScreenContentCallback = FullScreenContentCallback(
    onAdDismissedFullScreenContent: (dismissedAd) {
      dismissedAd.dispose();
      if (!rewardCompleter.isCompleted) {
        rewardCompleter.complete(rewardEarned);
      }
    },
    onAdFailedToShowFullScreenContent: (failedAd, error) {
      failedAd.dispose();
      if (!rewardCompleter.isCompleted) {
        rewardCompleter.completeError(
          Exception('No se pudo mostrar el anuncio'),
        );
      }
    },
  );
  ad.setImmersiveMode(true);
  ad.show(
    onUserEarnedReward: (shownAd, reward) {
      rewardEarned = true;
    },
  );

  return rewardCompleter.future;
}

Future<bool> confirmarAnuncioFotoPerfil(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: const Text('Reemplazar foto de perfil'),
        content: const Text(
          'Para usar esta selfie como foto de perfil tienes que ver un anuncio.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Ver anuncio'),
          ),
        ],
      );
    },
  );

  return confirmed == true;
}

class _MontageAdConfirmationDialog extends StatefulWidget {
  final String title;
  final String message;
  final String confirmText;
  final String accion;

  const _MontageAdConfirmationDialog({
    required this.title,
    required this.message,
    required this.confirmText,
    required this.accion,
  });

  @override
  State<_MontageAdConfirmationDialog> createState() =>
      _MontageAdConfirmationDialogState();
}

class _MontageAdConfirmationDialogState
    extends State<_MontageAdConfirmationDialog> {
  bool loadingAd = false;
  bool adWatched = false;
  String? statusMessage;

  Future<void> _watchAd() async {
    if (loadingAd || adWatched) return;

    setState(() {
      loadingAd = true;
      statusMessage = 'Cargando anuncio...';
    });

    try {
      final rewardEarned = await mostrarAnuncioRecompensado();
      if (!mounted) return;

      if (rewardEarned) {
        setState(() {
          adWatched = true;
          loadingAd = false;
          statusMessage =
              'Anuncio completado. Preparando montaje para ${widget.accion}...';
        });
        await Future<void>.delayed(const Duration(milliseconds: 350));
        if (mounted) Navigator.pop(context, true);
        return;
      }

      setState(() {
        loadingAd = false;
        statusMessage = 'Completa el anuncio para ${widget.accion} el montaje.';
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        loadingAd = false;
        statusMessage =
            'No se pudo cargar el anuncio. Inténtalo de nuevo en unos segundos.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final statusIcon = loadingAd
        ? Icons.hourglass_top_rounded
        : adWatched
        ? Icons.check_rounded
        : Icons.play_circle_outline_rounded;
    final statusColor = adWatched ? ssOrangeDark : ssText2;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28),
      child: Container(
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
        decoration: BoxDecoration(
          color: ssBg,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: ssBorder, width: 1.2),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.10),
              blurRadius: 28,
              offset: const Offset(0, 14),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: ssOrangeLight,
                    shape: BoxShape.circle,
                    border: Border.all(color: ssOrangeMid, width: 1.2),
                  ),
                  child: Icon(statusIcon, color: ssOrangeDark, size: 25),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: ssTitle,
                      fontSize: 21,
                      height: 1.05,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              widget.message,
              style: const TextStyle(
                color: ssText2,
                fontSize: 15,
                height: 1.35,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (statusMessage != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: 11,
                ),
                decoration: BoxDecoration(
                  color: adWatched ? ssOrangeLight : ssSeparator,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: adWatched ? ssOrangeMid : ssBorder),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(statusIcon, color: statusColor, size: 18),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        statusMessage!,
                        style: TextStyle(
                          color: statusColor,
                          fontSize: 13.5,
                          height: 1.28,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 22),
            Row(
              children: [
                Expanded(
                  child: _SundayAdDialogButton(
                    text: 'Cancelar',
                    onTap: loadingAd
                        ? null
                        : () => Navigator.pop(context, false),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _SundayAdDialogButton(
                    text: loadingAd
                        ? 'Cargando'
                        : adWatched
                        ? 'Listo'
                        : widget.confirmText,
                    primary: true,
                    onTap: loadingAd || adWatched ? null : _watchAd,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SundayAdDialogButton extends StatelessWidget {
  final String text;
  final VoidCallback? onTap;
  final bool primary;

  const _SundayAdDialogButton({
    required this.text,
    required this.onTap,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(16);
    final enabled = onTap != null;

    return Material(
      color: !enabled
          ? ssSeparator
          : primary
          ? ssOrange
          : ssOrangeLight,
      borderRadius: borderRadius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 48,
          child: Center(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: !enabled
                    ? ssText3
                    : primary
                    ? Colors.white
                    : ssOrangeDark,
                fontSize: 14.5,
                fontWeight: FontWeight.w900,
                height: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<bool> confirmarAnuncioMontaje(
  BuildContext context, {
  required String accion,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) {
      return _MontageAdConfirmationDialog(
        title: '${accion[0].toUpperCase()}${accion.substring(1)} montaje',
        message: 'Para poder $accion el montaje es necesario ver un anuncio.',
        confirmText: 'Ver anuncio',
        accion: accion,
      );
    },
  );

  return confirmed == true;
}

Future<bool> prepararCambioFotoPerfilConAnuncio(BuildContext context) async {
  final confirmed = await confirmarAnuncioFotoPerfil(context);
  if (!confirmed || !context.mounted) return false;

  showSundaySnack(context, 'Cargando anuncio...');
  final rewardEarned = await mostrarAnuncioRecompensado();
  if (!context.mounted) return rewardEarned;

  if (rewardEarned) {
    showSundaySnack(context, 'Anuncio completado. Actualizando foto...');
  } else {
    showSundaySnack(
      context,
      'Completa el anuncio para reemplazar la foto de perfil',
    );
  }

  return rewardEarned;
}

Future<bool> prepararZumbidoExtraConAnuncio(BuildContext context) async {
  final confirmed = await confirmarAnuncioZumbidoExtra(context);
  if (!confirmed || !context.mounted) return false;

  showSundaySnack(context, 'Cargando anuncio...');
  final rewardEarned = await mostrarAnuncioRecompensadoZumbido();
  if (!context.mounted) return rewardEarned;

  if (rewardEarned) {
    showSundaySnack(
      context,
      'Anuncio completado. Ya puedes enviar el zumbido.',
    );
  } else {
    showSundaySnack(context, 'Completa el anuncio para enviar otro zumbido');
  }

  return rewardEarned;
}

Future<bool> prepararMontajeConAnuncio(
  BuildContext context, {
  required String accion,
}) async {
  final unlocked = await confirmarAnuncioMontaje(context, accion: accion);
  if (!context.mounted) return unlocked;

  if (unlocked) {
    showSundaySnack(context, 'Anuncio completado. Preparando montaje...');
  }

  return unlocked;
}

Future<bool> prepararSelfieConRetrasoConAnuncio(BuildContext context) async {
  final unlocked = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const LateSelfieUploadDialog(),
  );

  return unlocked == true;
}

class LateSelfieUploadDialog extends StatefulWidget {
  const LateSelfieUploadDialog({super.key});

  @override
  State<LateSelfieUploadDialog> createState() => _LateSelfieUploadDialogState();
}

class _LateSelfieUploadDialogState extends State<LateSelfieUploadDialog> {
  bool loadingAd = false;
  bool adWatched = false;
  String? message;

  Future<void> _watchAd() async {
    if (loadingAd || adWatched) return;

    setState(() {
      loadingAd = true;
      message = 'Cargando anuncio...';
    });

    try {
      final rewardEarned = await mostrarAnuncioRecompensado();
      if (!mounted) return;

      setState(() {
        adWatched = rewardEarned;
        loadingAd = false;
        message = rewardEarned
            ? 'Anuncio completado. Ya puedes subir tu Sunday Selfie.'
            : 'Completa el anuncio para subir con un día de retraso.';
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        loadingAd = false;
        message = 'No se pudo completar el anuncio: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final statusIcon = loadingAd
        ? Icons.hourglass_top_rounded
        : adWatched
        ? Icons.check_rounded
        : Icons.lock_clock_rounded;
    final statusColor = adWatched ? ssOrangeDark : ssText2;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 22),
          decoration: BoxDecoration(
            color: ssSurface,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: ssOrangeMid, width: 1.4),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.16),
                blurRadius: 34,
                offset: const Offset(0, 16),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(
                    color: ssOrangeLight,
                    shape: BoxShape.circle,
                    border: Border.all(color: ssOrangeMid),
                  ),
                  child: Icon(statusIcon, color: ssOrangeDark, size: 30),
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Subir con un día de retraso',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: ssText,
                  fontSize: 23,
                  height: 1.12,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Para poder subir el Sunday Selfie el lunes hay que ver un anuncio.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: ssText2,
                  fontSize: 15,
                  height: 1.42,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (message != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: adWatched ? ssOrangeLight : ssSeparator,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: adWatched ? ssOrangeMid : ssBorder,
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(statusIcon, color: statusColor, size: 19),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          message!,
                          style: TextStyle(
                            color: statusColor,
                            fontSize: 14,
                            height: 1.35,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 22),
              TextButton.icon(
                onPressed: loadingAd
                    ? null
                    : () => Navigator.pop(context, false),
                icon: const Icon(Icons.close_rounded, size: 19),
                label: const Text('Cancelar'),
                style: TextButton.styleFrom(
                  foregroundColor: ssOrangeDark,
                  disabledForegroundColor: ssText3,
                  textStyle: const TextStyle(fontWeight: FontWeight.w800),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: loadingAd || adWatched ? null : _watchAd,
                icon: loadingAd
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          color: ssOrange,
                          strokeWidth: 2.2,
                        ),
                      )
                    : Icon(
                        adWatched
                            ? Icons.check_rounded
                            : Icons.play_circle_outline_rounded,
                        size: 19,
                      ),
                label: Text(
                  adWatched
                      ? 'Anuncio visto'
                      : loadingAd
                      ? 'Cargando anuncio'
                      : 'Ver anuncio',
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: ssOrangeDark,
                  disabledForegroundColor: ssText3,
                  side: BorderSide(color: adWatched ? ssBorder : ssOrangeMid),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  textStyle: const TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
              const SizedBox(height: 10),
              ElevatedButton.icon(
                onPressed: loadingAd || !adWatched
                    ? null
                    : () => Navigator.pop(context, true),
                icon: const Icon(Icons.photo_camera_rounded, size: 19),
                label: const Text('Subir Sunday Selfie'),
                style: ElevatedButton.styleFrom(
                  elevation: 0,
                  backgroundColor: ssOrange,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: ssSeparator,
                  disabledForegroundColor: ssText3,
                  shadowColor: Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  textStyle: const TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

const Map<String, String> kSelfieReportReasons = {
  'contenido_inapropiado': 'Contenido inapropiado',
  'acoso': 'Acoso o intimidación',
  'spam': 'Spam o contenido engañoso',
  'otro': 'Otro motivo',
};

Future<void> reportarSelfie({
  required String groupId,
  required String weekKey,
  required String postUid,
  required String reason,
}) async {
  if (!kSelfieReportReasons.containsKey(reason)) {
    throw Exception('Elige un motivo válido');
  }

  try {
    final callable = FirebaseFunctions.instance.httpsCallable(
      'reportarContenido',
    );

    await callable.call<void>({
      'groupId': groupId,
      'weekKey': weekKey,
      'postUid': postUid,
      'reason': reason,
    });
  } on FirebaseFunctionsException catch (error) {
    throw Exception(error.message ?? 'No se pudo enviar el reporte');
  }
}

Future<void> borrarSelfie({
  required String groupId,
  required String weekKey,
  required String postUid,
}) async {
  try {
    final callable = FirebaseFunctions.instance.httpsCallable('borrarSelfie');

    await callable.call<void>({
      'groupId': groupId,
      'weekKey': weekKey,
      'postUid': postUid,
    });
  } on FirebaseFunctionsException catch (error) {
    throw Exception(error.message ?? 'No se pudo borrar la selfie');
  }
}

const String kModerationDecisionDismiss = 'dismiss';
const String kModerationDecisionRemoveSelfie = 'remove_selfie';

DateTime? moderationDateFromMillis(dynamic value) {
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  if (value is double) {
    return DateTime.fromMillisecondsSinceEpoch(value.round());
  }
  return null;
}

class ModerationReport {
  final String reportId;
  final String groupId;
  final String weekKey;
  final String postUid;
  final String reason;
  final String status;
  final String authorName;
  final String? authorPhotoUrl;
  final String imageUrl;
  final String thumbUrl;
  final bool postExists;
  final DateTime? createdAt;

  const ModerationReport({
    required this.reportId,
    required this.groupId,
    required this.weekKey,
    required this.postUid,
    required this.reason,
    required this.status,
    required this.authorName,
    required this.authorPhotoUrl,
    required this.imageUrl,
    required this.thumbUrl,
    required this.postExists,
    required this.createdAt,
  });

  factory ModerationReport.fromData(Map<String, dynamic> data) {
    final rawAuthorPhoto = data['authorPhotoUrl'];
    final rawImageUrl = (data['imageUrl'] ?? '').toString().trim();
    final rawThumbUrl = (data['thumbUrl'] ?? '').toString().trim();

    return ModerationReport(
      reportId: (data['reportId'] ?? '').toString(),
      groupId: (data['groupId'] ?? '').toString(),
      weekKey: (data['weekKey'] ?? '').toString(),
      postUid: (data['postUid'] ?? '').toString(),
      reason: (data['reason'] ?? 'otro').toString(),
      status: (data['status'] ?? 'pending').toString(),
      authorName: formatUserDisplayName(data['authorName'] ?? 'Usuario'),
      authorPhotoUrl:
          rawAuthorPhoto is String && rawAuthorPhoto.trim().isNotEmpty
          ? rawAuthorPhoto.trim()
          : null,
      imageUrl: rawImageUrl,
      thumbUrl: rawThumbUrl.isEmpty ? rawImageUrl : rawThumbUrl,
      postExists: data['postExists'] == true,
      createdAt: moderationDateFromMillis(data['createdAtMillis']),
    );
  }

  String get reasonLabel => kSelfieReportReasons[reason] ?? 'Otro motivo';
}

Future<List<ModerationReport>> listarReportesGrupo({
  required String groupId,
}) async {
  try {
    final callable = FirebaseFunctions.instance.httpsCallable(
      'listarReportesGrupo',
    );
    final result = await callable.call<dynamic>({'groupId': groupId});
    final data = result.data;

    if (data is! Map) {
      throw Exception('Firebase no devolvió reportes válidos');
    }

    final rawReports = data['reports'];
    if (rawReports is! List) return [];

    return rawReports
        .whereType<Map>()
        .map((raw) => ModerationReport.fromData(Map<String, dynamic>.from(raw)))
        .toList();
  } on FirebaseFunctionsException catch (error) {
    throw Exception(error.message ?? 'No se pudieron cargar los reportes');
  }
}

Future<void> resolverReporteGrupo({
  required String reportId,
  required String decision,
}) async {
  if (decision != kModerationDecisionDismiss &&
      decision != kModerationDecisionRemoveSelfie) {
    throw Exception('Decisión de moderación no válida');
  }

  try {
    final callable = FirebaseFunctions.instance.httpsCallable(
      'resolverReporte',
    );

    await callable.call<void>({'reportId': reportId, 'decision': decision});
  } on FirebaseFunctionsException catch (error) {
    throw Exception(error.message ?? 'No se pudo resolver el reporte');
  }
}

Future<void> borrarCuentaSundaySelfie() async {
  try {
    final callable = FirebaseFunctions.instance.httpsCallable('borrarCuenta');

    await callable.call<void>({'confirmation': 'BORRAR'});
  } on FirebaseFunctionsException catch (error) {
    throw Exception(error.message ?? 'No se pudo borrar la cuenta');
  }
}

Future<void> enviarSugerenciaUsuario({
  required User user,
  required String authorName,
  required String text,
}) async {
  final cleanText = text.trim();
  if (cleanText.length < 5) {
    throw Exception('Escribe un poco más para enviar la sugerencia');
  }
  if (cleanText.length > 1000) {
    throw Exception('La sugerencia no puede superar 1000 caracteres');
  }

  final cleanAuthorName = formatUserDisplayName(authorName).trim();
  final safeAuthorName = cleanAuthorName.length > 80
      ? cleanAuthorName.substring(0, 80)
      : cleanAuthorName;
  final cleanEmail = user.email?.trim();
  final safeEmail =
      cleanEmail != null && cleanEmail.isNotEmpty && cleanEmail.length <= 320
      ? cleanEmail
      : null;

  try {
    final callable = FirebaseFunctions.instance.httpsCallable(
      'enviarSugerencia',
    );
    final payload = <String, Object>{
      'authorName': safeAuthorName.isEmpty ? 'Usuario' : safeAuthorName,
      'text': cleanText,
    };

    if (safeEmail != null) payload['authorEmail'] = safeEmail;

    final result = await callable.call<dynamic>(payload);
    final resultData = result.data;
    final emailStatus = resultData is Map
        ? resultData['emailStatus']?.toString()
        : null;

    if (emailStatus == 'failed' || emailStatus == 'not_configured') {
      throw Exception(
        'La sugerencia se guardó, pero el correo no quedó configurado',
      );
    }
  } on FirebaseFunctionsException catch (error) {
    throw Exception(error.message ?? 'No se pudo enviar la sugerencia');
  }
}

Future<void> enviarMensajeChatSemana({
  required String groupId,
  required String weekKey,
  required String text,
  String? gifUrl,
  String? gifLabel,
}) async {
  final currentUser = FirebaseAuth.instance.currentUser;

  if (currentUser == null) {
    throw Exception('No hay usuario autenticado');
  }

  final cleanText = text.trim();
  final cleanGifUrl = gifUrl?.trim() ?? '';
  final cleanGifLabel = gifLabel?.trim() ?? '';

  if (cleanText.isEmpty && cleanGifUrl.isEmpty) {
    throw Exception('Escribe un mensaje o elige un GIF');
  }

  if (cleanText.characters.length > 500) {
    throw Exception('El mensaje no puede superar 500 caracteres');
  }

  if (cleanGifUrl.isNotEmpty) {
    final uri = Uri.tryParse(cleanGifUrl);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw Exception('El GIF no es válido');
    }
  }

  if (!esDomingo() || weekKey != obtenerWeekKeyActual()) {
    throw Exception('El chat solo está abierto los domingos');
  }

  final firestore = FirebaseFirestore.instance;
  final memberRef = firestore
      .collection('groups')
      .doc(groupId)
      .collection('members')
      .doc(currentUser.uid);

  final memberDoc = await memberRef.get();

  if (!memberDoc.exists) {
    throw Exception('No perteneces a este grupo');
  }

  final memberData = memberDoc.data() ?? {};
  final authorName = formatUserDisplayName(
    memberData['effectiveName'] ?? currentUser.displayName ?? 'Usuario',
  );
  final authorPhotoUrl = memberData['effectivePhotoUrl'];

  final weekRef = firestore
      .collection('groups')
      .doc(groupId)
      .collection('weeks')
      .doc(weekKey);
  final messageRef = weekRef.collection('chatMessages').doc();
  final now = DateTime.now();

  await firestore.runTransaction((transaction) async {
    final weekDoc = await transaction.get(weekRef);

    if (!weekDoc.exists) {
      transaction.set(weekRef, {
        'weekKey': weekKey,
        'isoYear': calcularAnioISO(now),
        'isoWeek': calcularNumeroSemanaISO(now),
        'createdAt': FieldValue.serverTimestamp(),
        'postCount': 0,
      });
    }

    transaction.set(messageRef, {
      'uid': currentUser.uid,
      'authorName': authorName,
      'authorPhotoUrl': authorPhotoUrl,
      'text': cleanText,
      'type': cleanGifUrl.isEmpty
          ? 'text'
          : (cleanText.isEmpty ? 'gif' : 'mixed'),
      'gifUrl': cleanGifUrl.isEmpty ? null : cleanGifUrl,
      'gifLabel': cleanGifLabel.isEmpty ? null : cleanGifLabel,
      'weekKey': weekKey,
      'createdAt': FieldValue.serverTimestamp(),
    });
  });

  await marcarActividadGrupo(groupId: groupId);
}

Future<void> marcarChatSemanaLeido({
  required String groupId,
  required String weekKey,
}) async {
  final currentUser = FirebaseAuth.instance.currentUser;

  if (currentUser == null || weekKey.isEmpty) return;

  await FirebaseFirestore.instance
      .collection('users')
      .doc(currentUser.uid)
      .collection('groups')
      .doc(groupId)
      .set({
        'groupId': groupId,
        'chatReads': {
          weekKey: {'lastReadAt': FieldValue.serverTimestamp()},
        },
      }, SetOptions(merge: true));
}

Future<void> marcarGrupoSemanaVisto({
  required String groupId,
  required String weekKey,
}) async {
  final currentUser = FirebaseAuth.instance.currentUser;

  if (currentUser == null || weekKey.isEmpty) return;

  await FirebaseFirestore.instance
      .collection('users')
      .doc(currentUser.uid)
      .collection('groups')
      .doc(groupId)
      .set({
        'groupId': groupId,
        'groupViews': {
          weekKey: {'lastViewedAt': FieldValue.serverTimestamp()},
        },
      }, SetOptions(merge: true));
}

class StreakRankingEntry {
  final String uid;
  final String name;
  final String? photoUrl;
  final int streak;
  final bool isCurrentUser;

  const StreakRankingEntry({
    required this.uid,
    required this.name,
    required this.photoUrl,
    required this.streak,
    required this.isCurrentUser,
  });
}

Future<List<StreakRankingEntry>> calcularRankingRachasGrupo({
  required String groupId,
  required String currentUid,
}) async {
  final firestore = FirebaseFirestore.instance;
  final membersSnapshot = await firestore
      .collection('groups')
      .doc(groupId)
      .collection('members')
      .get();

  final entries = <StreakRankingEntry>[];

  for (final memberDoc in membersSnapshot.docs) {
    final data = memberDoc.data();
    final name = formatUserDisplayName(data['effectiveName'] ?? 'Usuario');
    final photoUrl = data['effectivePhotoUrl'] as String?;
    final streak = await calcularRachaPublicacionUsuarioEnGrupo(
      groupId: groupId,
      uid: memberDoc.id,
    );

    entries.add(
      StreakRankingEntry(
        uid: memberDoc.id,
        name: name,
        photoUrl: photoUrl,
        streak: streak,
        isCurrentUser: memberDoc.id == currentUid,
      ),
    );
  }

  entries.sort((a, b) {
    final streakCompare = b.streak.compareTo(a.streak);
    if (streakCompare != 0) return streakCompare;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });

  return entries;
}

Future<List<XFile>> descargarSelfiesGrupo({
  required String groupId,
  required String groupName,
  required bool allWeeks,
  String? weekKey,
  List<String>? weekKeys,
}) async {
  final firestore = FirebaseFirestore.instance;
  final sanitizedGroupName = groupName
      .replaceAll(RegExp(r'[^A-Za-z0-9_\-]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .trim();

  final weekIds = <String>[];

  final explicitWeekKeys = weekKeys
      ?.map((key) => key.trim())
      .where((key) => key.isNotEmpty)
      .toSet()
      .toList();

  if (explicitWeekKeys != null && explicitWeekKeys.isNotEmpty) {
    weekIds.addAll(explicitWeekKeys);
  } else if (allWeeks) {
    final weeksSnapshot = await firestore
        .collection('groups')
        .doc(groupId)
        .collection('weeks')
        .orderBy('createdAt', descending: true)
        .get();
    weekIds.addAll(weeksSnapshot.docs.map((doc) => doc.id));
  } else {
    weekIds.add(weekKey ?? obtenerWeekKeyActual());
  }

  final files = <XFile>[];
  final httpClient = HttpClient();

  try {
    for (final currentWeekKey in weekIds) {
      final postsSnapshot = await firestore
          .collection('groups')
          .doc(groupId)
          .collection('weeks')
          .doc(currentWeekKey)
          .collection('posts')
          .get();

      for (final postDoc in postsSnapshot.docs) {
        final data = postDoc.data();
        final imageUrl = (data['imageUrl'] ?? data['thumbUrl'] ?? '')
            .toString();
        if (imageUrl.trim().isEmpty) continue;

        final authorName =
            formatUserDisplayName(data['authorName'] ?? postDoc.id)
                .replaceAll(RegExp(r'[^A-Za-z0-9_\-]+'), '_')
                .replaceAll(RegExp(r'_+'), '_')
                .trim();
        final uri = Uri.tryParse(imageUrl);
        if (uri == null) continue;

        final request = await httpClient.getUrl(uri);
        final response = await request.close();
        if (response.statusCode < 200 || response.statusCode >= 300) continue;

        final bytes = await consolidateHttpClientResponseBytes(response);
        final fileName =
            '${sanitizedGroupName.isEmpty ? 'grupo' : sanitizedGroupName}_${currentWeekKey}_${authorName.isEmpty ? postDoc.id : authorName}.jpg';
        final file = File('${Directory.systemTemp.path}/$fileName');
        await file.writeAsBytes(bytes, flush: true);
        files.add(XFile(file.path, mimeType: 'image/jpeg', name: fileName));
      }
    }
  } finally {
    httpClient.close(force: true);
  }

  return files;
}

String sanitizarParteNombreArchivo(String value, String fallback) {
  final sanitized = value
      .replaceAll(RegExp(r'[^A-Za-z0-9_\-]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .trim();
  return sanitized.isEmpty ? fallback : sanitized;
}

String extensionImagenParaMimeType(String mimeType) {
  switch (mimeType.toLowerCase()) {
    case 'image/png':
      return 'png';
    case 'image/webp':
      return 'webp';
    case 'image/heic':
      return 'heic';
    case 'image/heif':
      return 'heif';
    default:
      return 'jpg';
  }
}

Future<XFile> descargarSelfieIndividual({
  required String imageUrl,
  required String groupName,
  required String weekKey,
  required String authorName,
}) async {
  final trimmedUrl = imageUrl.trim();
  if (trimmedUrl.isEmpty) {
    throw Exception('Esta selfie no tiene una imagen disponible');
  }

  final uri = Uri.tryParse(trimmedUrl);
  if (uri == null || !uri.hasScheme) {
    throw Exception('No se pudo preparar la descarga');
  }

  final httpClient = HttpClient();
  try {
    final request = await httpClient.getUrl(uri);
    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('No se pudo descargar la selfie');
    }

    final bytes = await consolidateHttpClientResponseBytes(response);
    final mimeType = response.headers.contentType?.mimeType ?? 'image/jpeg';
    final extension = extensionImagenParaMimeType(mimeType);
    final safeGroupName = sanitizarParteNombreArchivo(groupName, 'grupo');
    final safeWeekKey = sanitizarParteNombreArchivo(weekKey, 'semana');
    final safeAuthorName = sanitizarParteNombreArchivo(authorName, 'selfie');
    final fileName =
        'selfie_${safeGroupName}_${safeWeekKey}_$safeAuthorName.$extension';
    final file = File('${Directory.systemTemp.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    return XFile(file.path, mimeType: mimeType, name: fileName);
  } finally {
    httpClient.close(force: true);
  }
}

Future<void> compartirArchivosDescargados({
  required BuildContext context,
  required List<XFile> files,
  required String title,
}) async {
  if (files.isEmpty) {
    if (context.mounted) {
      showSundaySnack(context, 'No hay selfies para descargar');
    }
    return;
  }

  await SharePlus.instance.share(
    ShareParams(
      files: files,
      text: title,
      subject: title,
      sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1),
    ),
  );
}

Future<int> guardarArchivosDescargadosEnTelefono({
  required List<XFile> files,
}) async {
  if (files.isEmpty) return 0;

  if (!Platform.isAndroid && !Platform.isIOS) {
    throw UnsupportedError(
      'La descarga directa solo está disponible en teléfono',
    );
  }

  final savedCount = await mediaSaverChannel.invokeMethod<int>(
    'saveImagesToGallery',
    {
      'files': files
          .map(
            (file) => {
              'path': file.path,
              'name': file.name,
              'mimeType': file.mimeType ?? 'image/jpeg',
            },
          )
          .toList(),
    },
  );

  return savedCount ?? 0;
}

String mensajeErrorGuardandoArchivos(Object error) {
  if (error is PlatformException) {
    switch (error.code) {
      case 'photo-permission-denied':
        return 'Activa el permiso de Fotos para guardar las selfies';
      case 'no-files-saved':
        return 'No se pudieron guardar las selfies en el teléfono';
      case 'save-failed':
        return 'No se pudieron guardar las selfies en el teléfono';
      case 'invalid-arguments':
        return 'No se pudo preparar la descarga';
    }

    final message = error.message?.trim();
    if (message != null && message.isNotEmpty) return message;
  }

  if (error is UnsupportedError) {
    return error.message ?? 'La descarga directa no está disponible aquí';
  }

  return 'Error guardando selfies: $error';
}

void showReactionUsersSheet({
  required BuildContext context,
  required String emoji,
  required List<QueryDocumentSnapshot<Map<String, dynamic>>> reactions,
}) {
  final users = reactions.where((doc) {
    final value = (doc.data()['emoji'] ?? '').toString().trim();
    return value == emoji;
  }).toList();

  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) {
      return SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 38,
                height: 4,
                margin: const EdgeInsets.only(bottom: 18),
                decoration: BoxDecoration(
                  color: ssBorder,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              Row(
                children: [
                  Text(emoji, style: const TextStyle(fontSize: 24)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      users.length == 1
                          ? '1 reacción'
                          : '${users.length} reacciones',
                      style: const TextStyle(
                        color: ssTitle,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              ...users.map((doc) {
                final data = doc.data();
                final name = formatUserDisplayName(
                  data['authorName'] ?? 'Usuario',
                );
                final photoUrl = data['authorPhotoUrl'] as String?;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Row(
                    children: [
                      MiniProfileAvatar(
                        name: name,
                        photoUrl: photoUrl,
                        size: 38,
                        borderColor: ssBg,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          name,
                          style: const TextStyle(
                            color: ssTitle,
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
      );
    },
  );
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final AppLinks _appLinks = AppLinks();
  late final SundayClock _sundayClock;
  StreamSubscription<Uri>? _linkSubscription;
  StreamSubscription<User?>? _authSubscription;
  String? _pendingInviteInput;
  String? _lastOpenedInviteInput;
  bool _pendingInviteFrameScheduled = false;

  @override
  void initState() {
    super.initState();
    _sundayClock = SundayClock();
    _linkSubscription = _appLinks.uriLinkStream.listen(
      _handleIncomingLink,
      onError: (error) {
        logDebug('No se pudo leer el enlace de invitación: $error');
      },
    );
    unawaited(_handleInitialLink());
    _authSubscription = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (user != null) {
        _openPendingInvite(user);
      }
    });
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    _authSubscription?.cancel();
    _sundayClock.dispose();
    super.dispose();
  }

  Future<void> _handleInitialLink() async {
    try {
      final uri = await _appLinks.getInitialLink();
      if (uri == null) return;
      await _handleIncomingLink(uri);
    } catch (error) {
      logDebug('No se pudo leer el enlace inicial de invitación: $error');
    }
  }

  Future<void> _handleIncomingLink(Uri uri) async {
    final inviteInput = obtenerInvitacionDesdeDeepLink(uri);
    if (inviteInput == null) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _pendingInviteInput = inviteInput;
      _lastOpenedInviteInput = null;
      return;
    }

    await _openInvite(user: user, inviteInput: inviteInput);
  }

  void _openPendingInvite(User user) {
    final inviteInput = _pendingInviteInput;
    if (inviteInput == null) return;

    _pendingInviteInput = null;
    unawaited(_openInvite(user: user, inviteInput: inviteInput));
  }

  void _schedulePendingInviteOpen() {
    if (_pendingInviteFrameScheduled) return;
    _pendingInviteFrameScheduled = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingInviteFrameScheduled = false;
      if (!mounted) return;

      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        _openPendingInvite(user);
      }
    });
  }

  Future<void> _openInvite({
    required User user,
    required String inviteInput,
  }) async {
    if (_lastOpenedInviteInput == inviteInput) return;
    _lastOpenedInviteInput = inviteInput;

    final navigator = sundayNavigatorKey.currentState;
    if (navigator == null) {
      _pendingInviteInput = inviteInput;
      _lastOpenedInviteInput = null;
      _schedulePendingInviteOpen();
      return;
    }

    final groupId = await resolverGroupIdDesdeInvitacion(inviteInput);
    if (groupId == null) {
      _showRootSnack('Invitación no válida');
      return;
    }

    navigator.push(
      MaterialPageRoute(
        builder: (_) =>
            JoinGroupScreen(user: user, initialInviteInput: inviteInput),
      ),
    );
  }

  void _showRootSnack(String message) {
    final context = sundayNavigatorKey.currentContext;
    if (context == null) return;
    showSundaySnack(context, message);
  }

  @override
  Widget build(BuildContext context) {
    return SundayClockScope(
      clock: _sundayClock,
      child: MaterialApp(
        navigatorKey: sundayNavigatorKey,
        debugShowCheckedModeBanner: false,
        title: 'Sunday Selfie',
        theme: ThemeData(
          useMaterial3: true,
          scaffoldBackgroundColor: ssBg,
          colorScheme: ColorScheme.fromSeed(
            seedColor: ssOrange,
            brightness: Brightness.light,
          ),
          textTheme: GoogleFonts.dmSansTextTheme(),
        ),
        home: StreamBuilder<User?>(
          stream: FirebaseAuth.instance.authStateChanges(),
          builder: (context, authSnapshot) {
            if (authSnapshot.connectionState == ConnectionState.waiting) {
              return const LoadingScreen();
            }

            if (authSnapshot.hasData) {
              return AuthenticatedUserGate(user: authSnapshot.data!);
            }

            return const LoginScreen();
          },
        ),
      ),
    );
  }
}

class AuthenticatedUserGate extends StatefulWidget {
  final User user;

  const AuthenticatedUserGate({super.key, required this.user});

  @override
  State<AuthenticatedUserGate> createState() => _AuthenticatedUserGateState();
}

class _AuthenticatedUserGateState extends State<AuthenticatedUserGate> {
  late Future<void> initialUserFuture;
  late Stream<DocumentSnapshot<Map<String, dynamic>>> userStream;
  late Widget authenticatedShell;

  @override
  void initState() {
    super.initState();
    initialUserFuture = crearUsuarioSiNoExiste(widget.user);
    userStream = FirebaseFirestore.instance
        .collection('users')
        .doc(widget.user.uid)
        .snapshots();
    authenticatedShell = SundayShell(user: widget.user);
  }

  @override
  void didUpdateWidget(covariant AuthenticatedUserGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.user.uid != widget.user.uid) {
      initialUserFuture = crearUsuarioSiNoExiste(widget.user);
      userStream = FirebaseFirestore.instance
          .collection('users')
          .doc(widget.user.uid)
          .snapshots();
      authenticatedShell = SundayShell(user: widget.user);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: initialUserFuture,
      builder: (context, setupSnapshot) {
        if (setupSnapshot.connectionState == ConnectionState.waiting) {
          return const LoadingScreen();
        }

        if (setupSnapshot.hasError) {
          return AuthSetupErrorScreen(
            error: setupSnapshot.error.toString(),
            onRetry: () {
              setState(() {
                initialUserFuture = crearUsuarioSiNoExiste(widget.user);
              });
            },
          );
        }

        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: userStream,
          builder: (context, userSnapshot) {
            if (userSnapshot.connectionState == ConnectionState.waiting) {
              return const LoadingScreen();
            }

            final userData = userSnapshot.data?.data();

            if (perfilInicialPendiente(userData)) {
              return OnboardingNameScreen(user: widget.user);
            }

            return authenticatedShell;
          },
        );
      },
    );
  }
}

class AuthSetupErrorScreen extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;

  const AuthSetupErrorScreen({
    super.key,
    required this.error,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ssBg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SundaySelfieLogoMark(size: 86),
              const SizedBox(height: 20),
              const Text(
                'No se pudo preparar tu perfil',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: ssTitle,
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                error,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: ssText2,
                  fontSize: 14,
                  height: 1.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 22),
              SundayButton(text: 'Reintentar', onPressed: onRetry),
              const SizedBox(height: 10),
              SundayButton(
                text: 'Cerrar sesión',
                variant: SundayButtonVariant.ghost,
                onPressed: () => FirebaseAuth.instance.signOut(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class OnboardingNameScreen extends StatefulWidget {
  final User user;

  const OnboardingNameScreen({super.key, required this.user});

  @override
  State<OnboardingNameScreen> createState() => _OnboardingNameScreenState();
}

class _OnboardingNameScreenState extends State<OnboardingNameScreen> {
  final TextEditingController nameController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final initialName = widget.user.displayName?.trim();
    if (initialName != null && initialName.isNotEmpty) {
      nameController.text = formatUserDisplayName(initialName);
    }
  }

  @override
  void dispose() {
    nameController.dispose();
    super.dispose();
  }

  void _continue() {
    final name = nameController.text.trim();

    if (name.isEmpty) {
      showSundaySnack(context, 'Escribe tu nombre para continuar');
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => OnboardingPhotoScreen(user: widget.user, name: name),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ssBg,
      body: SafeArea(
        child: Column(
          children: [
            const AppHeader(logoTapToHome: false),
            const OnboardingProgress(currentStep: 1, totalSteps: 2),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 28, 24, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Perfil Sunday Selfie',
                      style: TextStyle(
                        color: ssTitle,
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        height: 1.1,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Puedes cambiarlo en cualquier momento',
                      style: TextStyle(
                        color: ssText2,
                        fontSize: 14,
                        height: 1.45,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 28),
                    SundayTextField(
                      controller: nameController,
                      hintText: 'Tu nombre',
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _continue(),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 10, 24, 24),
              child: AnimatedBuilder(
                animation: nameController,
                builder: (context, _) {
                  final enabled = nameController.text.trim().isNotEmpty;
                  return SundayButton(
                    text: 'Siguiente',
                    onPressed: enabled ? _continue : null,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class OnboardingPhotoScreen extends StatefulWidget {
  final User user;
  final String name;

  const OnboardingPhotoScreen({
    super.key,
    required this.user,
    required this.name,
  });

  @override
  State<OnboardingPhotoScreen> createState() => _OnboardingPhotoScreenState();
}

class _OnboardingPhotoScreenState extends State<OnboardingPhotoScreen> {
  XFile? selectedPhoto;
  bool saving = false;

  Future<void> _choosePhotoSource() async {
    final source = await showModalBottomSheet<image_picker.ImageSource>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => const ProfilePhotoSourceSheet(),
    );

    if (!mounted || source == null) return;

    if (source == image_picker.ImageSource.camera) {
      final photo = await Navigator.push<XFile>(
        context,
        MaterialPageRoute(
          builder: (_) =>
              const CameraCaptureScreen(groupName: 'Foto de perfil'),
        ),
      );

      if (!mounted || photo == null) return;
      final validPhoto = await validarFotoSelfieParaSubida(context, photo);
      if (!mounted || !validPhoto) return;

      setState(() {
        selectedPhoto = photo;
      });
      return;
    }

    try {
      final picker = image_picker.ImagePicker();
      final photo = await picker.pickImage(
        source: image_picker.ImageSource.gallery,
        imageQuality: 88,
        maxWidth: 1600,
      );

      if (!mounted || photo == null) return;
      final validPhoto = await validarFotoSelfieParaSubida(context, photo);
      if (!mounted || !validPhoto) return;

      setState(() {
        selectedPhoto = photo;
      });
    } catch (error) {
      if (!mounted) return;
      showSundaySnack(context, 'No se pudo abrir la galería: $error');
    }
  }

  Future<void> _finish() async {
    final photo = selectedPhoto;

    if (photo == null) {
      showSundaySnack(context, 'Añade una foto de perfil para empezar');
      return;
    }

    final validPhoto = await validarFotoSelfieParaSubida(context, photo);
    if (!mounted || !validPhoto) return;

    if (saving) return;

    setState(() => saving = true);

    try {
      await actualizarPerfilInicialUsuario(
        user: widget.user,
        nombre: widget.name,
        foto: photo,
      );

      if (!mounted) return;
      Navigator.popUntil(context, (route) => route.isFirst);
    } on SelfiePhotoValidationException catch (error) {
      if (!mounted) return;
      showSundaySnack(context, error.message);
    } catch (error) {
      if (!mounted) return;
      showSundaySnack(context, 'Error guardando perfil: $error');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ssBg,
      body: SafeArea(
        child: Column(
          children: [
            const AppHeader(logoTapToHome: false),
            const OnboardingProgress(currentStep: 2, totalSteps: 2),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                children: [
                  const Text(
                    'Foto de perfil',
                    style: TextStyle(
                      color: ssTitle,
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'La foto de perfil se puede cambiar cada domingo',
                    style: TextStyle(
                      color: ssText2,
                      fontSize: 14,
                      height: 1.45,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 28),
                  Center(
                    child: OnboardingProfilePhotoPreview(
                      photo: selectedPhoto,
                      name: widget.name,
                      onTap: saving ? null : _choosePhotoSource,
                    ),
                  ),
                  const SizedBox(height: 28),
                  if (selectedPhoto == null)
                    SundayDashedActionCard(
                      icon: Icons.add_a_photo_outlined,
                      title: 'Añadir foto de perfil',
                      subtitle: 'Elige una imagen de galería o hazla ahora',
                      onTap: saving ? null : _choosePhotoSource,
                    )
                  else
                    SundayDashedActionCard(
                      icon: Icons.photo_library_outlined,
                      title: 'Cambiar foto de perfil',
                      subtitle: 'Elige otra imagen o haz una nueva',
                      onTap: saving ? null : _choosePhotoSource,
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 10, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SundayButton(
                    text: saving ? 'Guardando...' : '¡Empezar!',
                    onPressed: saving ? null : _finish,
                  ),
                  const SizedBox(height: 10),
                  SundayButton(
                    text: 'Atrás',
                    variant: SundayButtonVariant.ghost,
                    onPressed: saving ? null : () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class OnboardingProgress extends StatelessWidget {
  final int currentStep;
  final int totalSteps;

  const OnboardingProgress({
    super.key,
    required this.currentStep,
    required this.totalSteps,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
      child: Row(
        children: List.generate(totalSteps, (index) {
          final active = index < currentStep;
          return Expanded(
            child: Container(
              height: 3,
              margin: EdgeInsets.only(right: index == totalSteps - 1 ? 0 : 6),
              decoration: BoxDecoration(
                color: active ? ssOrange : ssBorder,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class SundayTextField extends StatelessWidget {
  final TextEditingController controller;
  final String hintText;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;

  const SundayTextField({
    super.key,
    required this.controller,
    required this.hintText,
    this.textInputAction,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      textInputAction: textInputAction,
      onSubmitted: onSubmitted,
      cursorColor: ssOrange,
      style: const TextStyle(
        color: ssText,
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: const TextStyle(
          color: ssText3,
          fontSize: 16,
          fontWeight: FontWeight.w500,
        ),
        filled: true,
        fillColor: ssBg,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: ssBorder, width: 1.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: ssOrange, width: 1.5),
        ),
      ),
    );
  }
}

class OnboardingProfilePhotoPreview extends StatelessWidget {
  final XFile? photo;
  final String name;
  final VoidCallback? onTap;

  const OnboardingProfilePhotoPreview({
    super.key,
    required this.photo,
    required this.name,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasPhoto = photo != null;

    return GestureDetector(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: hasPhoto ? ssOrange : ssBorder,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.10),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: ClipOval(
              child: hasPhoto
                  ? Image.file(
                      File(photo!.path),
                      width: 120,
                      height: 120,
                      fit: BoxFit.cover,
                      alignment: Alignment.center,
                      filterQuality: FilterQuality.high,
                      errorBuilder: (_, _, _) => Center(
                        child: Text(
                          initialsFromName(name),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 38,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    )
                  : const Center(
                      child: Icon(
                        Icons.person_outline_rounded,
                        color: ssText3,
                        size: 44,
                      ),
                    ),
            ),
          ),
          Positioned(
            right: 2,
            bottom: 2,
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: ssOrange,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2.5),
              ),
              child: const Icon(
                Icons.add_rounded,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SundayDashedBorderPainter extends CustomPainter {
  final Color color;
  final double radius;
  final double strokeWidth;
  final double dashLength;
  final double gapLength;

  const SundayDashedBorderPainter({
    required this.color,
    this.radius = 14,
    this.strokeWidth = 1.5,
    this.dashLength = 5,
    this.gapLength = 4,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(strokeWidth / 2),
      Radius.circular(radius),
    );

    final path = Path()..addRRect(rrect);
    final metrics = path.computeMetrics();
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    for (final metric in metrics) {
      double distance = 0;
      while (distance < metric.length) {
        final next = distance + dashLength;
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance = next + gapLength;
      }
    }
  }

  @override
  bool shouldRepaint(covariant SundayDashedBorderPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.radius != radius ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.dashLength != dashLength ||
        oldDelegate.gapLength != gapLength;
  }
}

class SundayDashedActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  const SundayDashedActionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: CustomPaint(
          painter: const SundayDashedBorderPainter(color: ssOrangeMid),
          child: Ink(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: const BoxDecoration(
                    color: ssOrangeLight,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: ssOrange, size: 21),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: ssTitle,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          color: ssText2,
                          fontSize: 12,
                          height: 1.3,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: ssOrange,
                  size: 24,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ProfilePhotoSourceSheet extends StatelessWidget {
  const ProfilePhotoSourceSheet({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: ssBorder,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(8, 0, 8, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Elige una foto',
                    style: TextStyle(
                      color: ssTitle,
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    '¿De dónde quieres añadirla?',
                    style: TextStyle(
                      color: ssText2,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              decoration: BoxDecoration(
                color: ssBg,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: ssBorder),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ProfilePhotoSourceRow(
                    icon: Icons.photo_library_outlined,
                    title: 'Galería',
                    subtitle: 'Elige una foto guardada',
                    onTap: () => Navigator.pop(
                      context,
                      image_picker.ImageSource.gallery,
                    ),
                  ),
                  const Divider(height: 1, color: ssSeparator),
                  ProfilePhotoSourceRow(
                    icon: Icons.photo_camera_outlined,
                    title: 'Cámara',
                    subtitle: 'Haz una foto ahora',
                    onTap: () =>
                        Navigator.pop(context, image_picker.ImageSource.camera),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Center(
                child: Text(
                  'Cancelar',
                  style: TextStyle(color: ssText2, fontWeight: FontWeight.w800),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ProfilePhotoSourceRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const ProfilePhotoSourceRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: ssOrangeLight,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: ssOrange, size: 21),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: ssTitle,
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: ssText2,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: ssText3),
            ],
          ),
        ),
      ),
    );
  }
}

class LoadingScreen extends StatelessWidget {
  const LoadingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: ssBg,
      body: Center(child: SundaySelfieLogoMark(size: 126)),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  String? signingInProvider;
  bool googleSignInInitialized = false;

  bool get signingIn => signingInProvider != null;

  Future<void> _signInWithGoogle() async {
    if (signingIn) return;

    setState(() => signingInProvider = 'google');

    try {
      if (!googleSignInInitialized) {
        await GoogleSignIn.instance.initialize(
          serverClientId: kGoogleServerClientId,
        );
        googleSignInInitialized = true;
      }

      final GoogleSignInAccount googleUser = await GoogleSignIn.instance
          .authenticate();
      final GoogleSignInAuthentication googleAuth = googleUser.authentication;

      final credential = GoogleAuthProvider.credential(
        idToken: googleAuth.idToken,
      );

      await FirebaseAuth.instance.signInWithCredential(credential);
    } on FirebaseAuthException catch (error) {
      if (!mounted) return;
      showSundaySnack(
        context,
        _firebaseAuthLoginMessage(error, providerName: 'Google'),
      );
    } catch (error) {
      if (!mounted) return;

      if (_loginWasCancelled(error)) {
        showSundaySnack(context, 'Inicio de sesión cancelado');
      } else {
        showSundaySnack(
          context,
          'No se pudo iniciar sesión con Google: $error',
        );
      }
    } finally {
      if (mounted) {
        setState(() => signingInProvider = null);
      }
    }
  }

  Future<void> _signInWithApple() async {
    if (signingIn) return;

    setState(() => signingInProvider = 'apple');

    try {
      final appleProvider = AppleAuthProvider()
        ..addScope('email')
        ..addScope('name');

      if (kIsWeb) {
        await FirebaseAuth.instance.signInWithPopup(appleProvider);
      } else {
        await FirebaseAuth.instance.signInWithProvider(appleProvider);
      }
    } on FirebaseAuthException catch (error) {
      if (!mounted) return;

      if (_loginWasCancelled(error)) {
        showSundaySnack(context, 'Inicio de sesión cancelado');
      } else {
        showSundaySnack(
          context,
          _firebaseAuthLoginMessage(error, providerName: 'Apple'),
        );
      }
    } catch (error) {
      if (!mounted) return;

      if (_loginWasCancelled(error)) {
        showSundaySnack(context, 'Inicio de sesión cancelado');
      } else {
        showSundaySnack(context, 'No se pudo iniciar sesión con Apple: $error');
      }
    } finally {
      if (mounted) {
        setState(() => signingInProvider = null);
      }
    }
  }

  bool _loginWasCancelled(Object error) {
    final rawError = error.toString().toLowerCase();
    if (rawError.contains('cancel') || rawError.contains('abort')) {
      return true;
    }

    return error is FirebaseAuthException &&
        {
          'cancelled-popup-request',
          'popup-closed-by-user',
          'web-context-cancelled',
        }.contains(error.code);
  }

  String _firebaseAuthLoginMessage(
    FirebaseAuthException error, {
    required String providerName,
  }) {
    switch (error.code) {
      case 'network-request-failed':
        return 'No hay conexión con Firebase. Revisa internet, DNS privado o VPN.';
      case 'operation-not-allowed':
        return '$providerName todavía no está activado como método de acceso en Firebase.';
      case 'account-exists-with-different-credential':
        return 'Ya existe una cuenta con otro método de acceso.';
      case 'invalid-credential':
        return providerName == 'Google'
            ? 'La credencial de Google no es válida. Revisa la configuración SHA en Firebase.'
            : 'La credencial de Apple no es válida. Revisa la configuración de Apple en Firebase.';
      default:
        return 'Error de acceso: ${error.message ?? error.code}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isSigningIn = signingIn;
    final isSigningInWithGoogle = signingInProvider == 'google';
    final isSigningInWithApple = signingInProvider == 'apple';

    return Scaffold(
      backgroundColor: ssBg,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final height = constraints.maxHeight;
            const loginLegalBottomInset = 24.0;

            return Stack(
              children: [
                Positioned(
                  left: 20,
                  right: 20,
                  top: height * 0.18,
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SundaySelfieLogoMark(size: 142),
                      SizedBox(height: 34),
                      SundayLogo(size: 48),
                      SizedBox(height: 10),
                      Text(
                        'Seguir conectados una vez por semana',
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: ssText2,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  left: 24,
                  right: 24,
                  top: height * 0.665,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FractionallySizedBox(
                        widthFactor: 0.78,
                        child: SizedBox(
                          height: 48,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.white,
                              foregroundColor: const Color(0xFF3C4043),
                              elevation: 1,
                              shadowColor: Colors.black.withValues(alpha: 0.08),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(24),
                                side: const BorderSide(
                                  color: Color(0xFFDADCE0),
                                ),
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                            ),
                            onPressed: isSigningIn ? null : _signInWithGoogle,
                            child: Row(
                              children: [
                                if (isSigningInWithGoogle)
                                  const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: ssOrange,
                                    ),
                                  )
                                else
                                  const GoogleGLogo(size: 20),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    isSigningInWithGoogle
                                        ? 'Conectando...'
                                        : 'Continuar con Google',
                                    textAlign: TextAlign.center,
                                    style: GoogleFonts.roboto(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w500,
                                      color: const Color(0xFF3C4043),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 20),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      FractionallySizedBox(
                        widthFactor: 0.78,
                        child: SizedBox(
                          height: 48,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.black,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(24),
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                            ),
                            onPressed: isSigningIn ? null : _signInWithApple,
                            child: Row(
                              children: [
                                if (isSigningInWithApple)
                                  const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                else
                                  const Icon(
                                    Icons.apple_rounded,
                                    color: Colors.white,
                                    size: 22,
                                  ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    isSigningInWithApple
                                        ? 'Conectando...'
                                        : 'Continuar con Apple',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w500,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 22),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  left: 24,
                  right: 24,
                  bottom: loginLegalBottomInset,
                  child: RichText(
                    textAlign: TextAlign.center,
                    text: const TextSpan(
                      style: TextStyle(
                        color: ssText3,
                        fontSize: 12,
                        height: 1.5,
                      ),
                      children: [
                        TextSpan(text: 'Al continuar aceptas nuestros '),
                        TextSpan(
                          text: 'Términos',
                          style: TextStyle(
                            color: ssOrange,
                            decoration: TextDecoration.underline,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        TextSpan(text: ' y '),
                        TextSpan(
                          text: 'Política de Privacidad',
                          style: TextStyle(
                            color: ssOrange,
                            decoration: TextDecoration.underline,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class GoogleGLogo extends StatelessWidget {
  final double size;

  const GoogleGLogo({super.key, this.size = 20});

  @override
  Widget build(BuildContext context) {
    return Image.memory(
      base64Decode(kGoogleGLogoPngBase64),
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
    );
  }
}

class SundayShell extends StatefulWidget {
  final User user;
  final int initialIndex;

  const SundayShell({super.key, required this.user, this.initialIndex = 0});

  @override
  State<SundayShell> createState() => _SundayShellState();
}

class _SundayShellState extends State<SundayShell> {
  late int selectedIndex;
  late List<Widget> pages;
  DateTime? pagesCalendarDay;
  StreamSubscription<RemoteMessage>? foregroundNotificationSubscription;
  StreamSubscription<RemoteMessage>? notificationOpenSubscription;
  String? lastHandledNotificationKey;

  @override
  void initState() {
    super.initState();
    selectedIndex = widget.initialIndex.clamp(0, 4).toInt();
    pages = buildPages(widget.user);
    pagesCalendarDay = inicioDiaLocal(DateTime.now());
    registrarTokenNotificaciones(widget.user);
    setupNotificationNavigation();
  }

  List<Widget> buildPages(User user) {
    return [
      HomeScreen(user: user),
      MySelfiesScreen(user: user),
      CameraTabScreen(user: user),
      MontageScreen(user: user),
      ProfileScreen(user: user),
    ];
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    SundayClockScope.watch(context);

    final today = inicioDiaLocal(DateTime.now());
    if (pagesCalendarDay != today) {
      pagesCalendarDay = today;
      pages = buildPages(widget.user);
    }
  }

  @override
  void didUpdateWidget(covariant SundayShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.user.uid != widget.user.uid) {
      pages = buildPages(widget.user);
      pagesCalendarDay = inicioDiaLocal(DateTime.now());
      registrarTokenNotificaciones(widget.user);
    }
  }

  @override
  void dispose() {
    foregroundNotificationSubscription?.cancel();
    notificationOpenSubscription?.cancel();
    if (Platform.isAndroid) {
      foregroundNotificationChannel.setMethodCallHandler(null);
    }
    super.dispose();
  }

  void setupNotificationNavigation() {
    if (Platform.isAndroid) {
      foregroundNotificationChannel.setMethodCallHandler((call) async {
        if (call.method != 'notificationTap') return;
        final payload = call.arguments;
        if (payload is String) {
          handleForegroundNotificationTap(payload);
        }
      });

      foregroundNotificationChannel
          .invokeMethod<String>('getLaunchPayload')
          .then((payload) {
            if (!mounted || payload == null || payload.isEmpty) return;
            handleForegroundNotificationTap(payload);
          })
          .catchError((error) {
            logDebug(
              'No se pudo leer la notificación foreground inicial: $error',
            );
          });
    }

    foregroundNotificationSubscription = FirebaseMessaging.onMessage.listen((
      message,
    ) {
      unawaited(mostrarNotificacionForegroundAndroid(message));
    });

    FirebaseMessaging.instance.getInitialMessage().then((message) {
      if (!mounted || message == null) return;
      handleNotificationNavigation(message);
    });

    notificationOpenSubscription = FirebaseMessaging.onMessageOpenedApp.listen(
      handleNotificationNavigation,
    );
  }

  void handleForegroundNotificationTap(String payload) {
    final message = remoteMessageFromForegroundPayload(payload);
    if (message == null) return;
    handleNotificationNavigation(message);
  }

  String notificationMessageKey(RemoteMessage message) {
    final data = message.data;

    return message.messageId ??
        [
          data['type'],
          data['target'],
          data['groupId'],
          data['weekKey'],
          data['authorUid'],
          data['postUid'],
          data['senderUid'],
          data['reactorUid'],
          data['requestUid'],
          data['memberUid'],
        ].join('|');
  }

  void handleNotificationNavigation(RemoteMessage message) {
    final key = notificationMessageKey(message);

    if (lastHandledNotificationKey == key) {
      return;
    }

    lastHandledNotificationKey = key;

    final data = message.data;
    final type = data['type']?.toString();
    final target = data['target']?.toString();
    final groupId = data['groupId']?.toString();

    logDebug('Notificación abierta: type=$type target=$target');

    if (target == 'group' &&
        {
          'new_selfie',
          'friend_reminder',
          'reaction',
          'new_member',
          'join_request',
          'join_accepted',
          'weekly_summary',
          'chat_message',
        }.contains(type) &&
        groupId != null &&
        groupId.isNotEmpty) {
      unawaited(
        openGroupFromNotification(
          groupId: groupId,
          type: type,
          weekKey: data['weekKey']?.toString(),
          postUid: (data['postUid'] ?? data['authorUid'])?.toString(),
        ),
      );
      return;
    }

    if (type == 'sunday_time' || target == 'home') {
      openHomeFromNotification();
      return;
    }
  }

  Future<void> openGroupFromNotification({
    required String groupId,
    String? type,
    String? weekKey,
    String? postUid,
  }) async {
    final validationMessage = await validateNotificationGroupDestination(
      groupId: groupId,
      type: type,
      weekKey: weekKey,
      postUid: postUid,
    );

    if (!mounted) return;

    if (validationMessage != null) {
      showSundaySnack(context, validationMessage);
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => GroupScreen(groupId: groupId)));
    });
  }

  Future<String?> validateNotificationGroupDestination({
    required String groupId,
    String? type,
    String? weekKey,
    String? postUid,
  }) async {
    final cleanGroupId = groupId.trim();
    if (cleanGroupId.isEmpty) return 'La notificación ya no está disponible';

    final firestore = FirebaseFirestore.instance;
    final groupRef = firestore.collection('groups').doc(cleanGroupId);

    try {
      final groupDoc = await groupRef.get();
      final groupData = groupDoc.data();

      if (!groupDoc.exists || groupData?['deleted'] == true) {
        return 'Este grupo ya no está disponible';
      }

      final memberDoc = await groupRef
          .collection('members')
          .doc(widget.user.uid)
          .get();

      if (!memberDoc.exists) {
        return 'Ya no perteneces a este grupo';
      }

      if ((type == 'new_selfie' || type == 'reaction') &&
          weekKey != null &&
          weekKey.trim().isNotEmpty &&
          postUid != null &&
          postUid.trim().isNotEmpty) {
        final postDoc = await groupRef
            .collection('weeks')
            .doc(weekKey.trim())
            .collection('posts')
            .doc(postUid.trim())
            .get();

        if (!postDoc.exists) {
          return 'Ese selfie ya no está disponible';
        }
      }
    } on FirebaseException catch (error) {
      if (error.code == 'permission-denied') {
        return 'Ya no tienes acceso a este contenido';
      }
      logDebug('No se pudo validar la notificación: $error');
      return 'No se pudo abrir la notificación';
    } catch (error) {
      logDebug('No se pudo validar la notificación: $error');
      return 'No se pudo abrir la notificación';
    }

    return null;
  }

  void openHomeFromNotification() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      if (selectedIndex != 0) {
        setState(() => selectedIndex = 0);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ssBg,
      body: IndexedStack(index: selectedIndex, children: pages),
      bottomNavigationBar: SundayTabBar(
        selectedIndex: selectedIndex,
        onSelected: (index) => setState(() => selectedIndex = index),
      ),
    );
  }
}

class SundayTabBar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  const SundayTabBar({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final items = [
      (Icons.groups_outlined, 'Grupos'),
      (Icons.grid_view_outlined, 'Mis selfies'),
      (Icons.photo_camera_outlined, 'Cámara'),
      (Icons.movie_outlined, 'Montaje'),
      (Icons.person_outline_rounded, 'Perfil'),
    ];

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          decoration: BoxDecoration(
            color: ssBg.withValues(alpha: 0.97),
            border: const Border(top: BorderSide(color: ssBorder)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 8),
              child: Row(
                children: List.generate(items.length, (index) {
                  final active = selectedIndex == index;
                  return Expanded(
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        splashFactory: NoSplash.splashFactory,
                        splashColor: Colors.transparent,
                        highlightColor: Colors.transparent,
                        hoverColor: Colors.transparent,
                        focusColor: Colors.transparent,
                        onTap: () => onSelected(index),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              items[index].$1,
                              size: 22,
                              color: active ? ssOrange : ssText3,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              items[index].$2,
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w500,
                                color: active ? ssOrange : ssText3,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final User user;

  const HomeScreen({super.key, required this.user});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController groupController = TextEditingController();
  final TextEditingController codeController = TextEditingController();
  bool creating = false;
  bool joining = false;
  late Stream<QuerySnapshot<Map<String, dynamic>>> userGroupsStream;

  @override
  void initState() {
    super.initState();
    userGroupsStream = FirebaseFirestore.instance
        .collection('users')
        .doc(widget.user.uid)
        .collection('groups')
        .snapshots();
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.user.uid != widget.user.uid) {
      userGroupsStream = FirebaseFirestore.instance
          .collection('users')
          .doc(widget.user.uid)
          .collection('groups')
          .snapshots();
    }
  }

  @override
  void dispose() {
    groupController.dispose();
    codeController.dispose();
    super.dispose();
  }

  Future<void> _showCreateJoinSheet() async {
    final navigator = Navigator.of(context);

    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: ssBorder,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                SundayActionCard(
                  icon: Icons.add_rounded,
                  title: 'Crear un grupo nuevo',
                  subtitle: 'Elige un nombre y empieza como administrador.',
                  onTap: () {
                    Navigator.pop(sheetContext);
                    Future.microtask(() {
                      navigator.push(
                        MaterialPageRoute(
                          builder: (_) => const CreateGroupScreen(),
                        ),
                      );
                    });
                  },
                ),
                const SizedBox(height: 12),
                SundayActionCard(
                  icon: Icons.link_rounded,
                  title: 'Unirme con código',
                  subtitle:
                      'Introduce el código que te ha pasado un administrador.',
                  onTap: () {
                    Navigator.pop(sheetContext);
                    Future.microtask(() {
                      navigator.push(
                        MaterialPageRoute(
                          builder: (_) => JoinGroupScreen(user: widget.user),
                        ),
                      );
                    });
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ssBg,
      body: SafeArea(
        child: Column(
          children: [
            const AppHeader(),
            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: userGroupsStream,
                builder: (context, groupsSnapshot) {
                  if (groupsSnapshot.connectionState ==
                      ConnectionState.waiting) {
                    return const Center(
                      child: CircularProgressIndicator(color: ssOrange),
                    );
                  }

                  if (groupsSnapshot.hasError) {
                    return Center(
                      child: Text(
                        'Error cargando grupos: ${groupsSnapshot.error}',
                      ),
                    );
                  }

                  final groupDocs = [...(groupsSnapshot.data?.docs ?? [])]
                    ..sort((a, b) {
                      final aData = a.data();
                      final bData = b.data();
                      final aValue = comparableTimestampMillis(
                        aData['lastActivityAt'] ?? aData['joinedAt'],
                      );
                      final bValue = comparableTimestampMillis(
                        bData['lastActivityAt'] ?? bData['joinedAt'],
                      );
                      return bValue.compareTo(aValue);
                    });

                  return ListView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
                    children: [
                      const SundayBanner(),
                      const SizedBox(height: 21),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final compact = constraints.maxWidth < 350;

                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                child: Text(
                                  'Mis grupos',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: ssTitle,
                                    fontSize: compact ? 20 : 22,
                                    fontWeight: FontWeight.w800,
                                    height: 1,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              SmallPillButton(
                                text: '+ Nuevo grupo',
                                onTap: _showCreateJoinSheet,
                              ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 16),
                      if (groupDocs.isEmpty) ...[
                        EmptyGroupsCard(onTap: _showCreateJoinSheet),
                        const SizedBox(height: 8),
                        InviteHintCard(onTap: _showCreateJoinSheet),
                      ] else ...[
                        ...groupDocs.map(
                          (doc) => RealGroupCard(
                            key: ValueKey('home_group_${doc.id}'),
                            userGroupDoc: doc,
                            currentUid: widget.user.uid,
                            onTap: () {
                              final data = doc.data();
                              final groupId = (data['groupId'] ?? doc.id)
                                  .toString();
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => GroupScreen(groupId: groupId),
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 2),
                        InviteHintCard(onTap: _showCreateJoinSheet),
                      ],
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class RealGroupCard extends StatefulWidget {
  final QueryDocumentSnapshot<Map<String, dynamic>> userGroupDoc;
  final String currentUid;
  final VoidCallback onTap;

  const RealGroupCard({
    super.key,
    required this.userGroupDoc,
    required this.currentUid,
    required this.onTap,
  });

  @override
  State<RealGroupCard> createState() => _RealGroupCardState();
}

class _RealGroupCardState extends State<RealGroupCard> {
  late String groupId;
  late Stream<DocumentSnapshot<Map<String, dynamic>>> groupStream;
  late Stream<QuerySnapshot<Map<String, dynamic>>> postsStream;
  String? postsStreamWeekKey;

  @override
  void initState() {
    super.initState();
    configureStreams();
  }

  @override
  void didUpdateWidget(covariant RealGroupCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldData = oldWidget.userGroupDoc.data();
    final newData = widget.userGroupDoc.data();
    final oldGroupId = (oldData['groupId'] ?? oldWidget.userGroupDoc.id)
        .toString();
    final newGroupId = (newData['groupId'] ?? widget.userGroupDoc.id)
        .toString();

    if (oldGroupId != newGroupId ||
        postsStreamWeekKey != obtenerWeekKeyVisibleMasReciente()) {
      configureStreams();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    SundayClockScope.watch(context);

    if (postsStreamWeekKey != obtenerWeekKeyVisibleMasReciente()) {
      configureStreams();
    }
  }

  void configureStreams() {
    final data = widget.userGroupDoc.data();
    groupId = (data['groupId'] ?? widget.userGroupDoc.id).toString();
    final weekKey = obtenerWeekKeyVisibleMasReciente();
    postsStreamWeekKey = weekKey;
    final groupRef = FirebaseFirestore.instance
        .collection('groups')
        .doc(groupId);
    groupStream = groupRef.snapshots();
    postsStream = groupRef
        .collection('weeks')
        .doc(weekKey)
        .collection('posts')
        .snapshots();
  }

  DateTime? _storedWeekTimestamp({
    required Map<String, dynamic> data,
    required String collectionKey,
    required String weekKey,
    required String field,
  }) {
    final collection = data[collectionKey];
    if (collection is! Map) return null;

    final weekState = collection[weekKey];
    if (weekState is! Map) return null;

    return timestampToDate(weekState[field]);
  }

  int _newSelfiesCount({
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> posts,
    required DateTime? lastViewedAt,
  }) {
    if (posts.isEmpty) return 0;

    var count = 0;
    for (final post in posts) {
      if (post.id == widget.currentUid) continue;
      if (lastViewedAt == null) {
        count += 1;
        continue;
      }

      final data = post.data();
      final postedAt =
          timestampToDate(data['updatedAt']) ??
          timestampToDate(data['createdAt']);
      if (postedAt != null && postedAt.isAfter(lastViewedAt)) {
        count += 1;
      }
    }

    return count;
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.userGroupDoc.data();
    final snapshotName = data['displayNameSnapshot'] ?? 'Grupo';

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: groupStream,
      builder: (context, groupSnapshot) {
        final groupData = groupSnapshot.data?.data();
        final name = groupData?['name'] ?? snapshotName;
        final memberCount = intFromValue(groupData?['memberCount']);
        final deleted = groupData?['deleted'] == true;

        if (deleted) return const SizedBox.shrink();

        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: postsStream,
          builder: (context, postsSnapshot) {
            final postDocs = postsSnapshot.data?.docs ?? [];
            for (final postDoc in postDocs) {
              prefetchPostPhotoCache(postDoc.data());
            }
            final postedCount = postDocs.length;
            final memberCountLabel = formatMemberCount(memberCount);
            final activeWeeks = semanasActivasDesdeCreatedAt(
              groupData?['createdAt'],
            );
            final activityLabel = esDomingo()
                ? '$postedCount/$memberCount han publicado'
                : formatActiveWeeksLabel(activeWeeks);

            final weekKey =
                postsStreamWeekKey ?? obtenerWeekKeyVisibleMasReciente();
            final lastViewedAt =
                _storedWeekTimestamp(
                  data: data,
                  collectionKey: 'groupViews',
                  weekKey: weekKey,
                  field: 'lastViewedAt',
                ) ??
                timestampToDate(data['joinedAt']);
            final pendingCount = _newSelfiesCount(
              posts: postDocs,
              lastViewedAt: lastViewedAt,
            );

            return SundayCard(
              onTap: widget.onTap,
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 44),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        GroupIcon(
                          name: name.toString(),
                          photoUrl: groupData?['photoUrl'] as String?,
                          emoji: groupData?['emoji'] as String?,
                          colorValue: groupData?['colorValue'],
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                formatGroupDisplayName(name),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: ssTitle,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                  height: 1.35,
                                ),
                              ),
                              const SizedBox(height: 2),
                              LayoutBuilder(
                                builder: (context, constraints) {
                                  return SizedBox(
                                    width: constraints.maxWidth,
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                        '$memberCountLabel · $activityLabel',
                                        maxLines: 1,
                                        softWrap: false,
                                        style: const TextStyle(
                                          color: ssText2,
                                          fontSize: 12.8,
                                          fontWeight: FontWeight.w600,
                                          height: 1.35,
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                              const SizedBox(height: 8),
                              GroupMembersAvatarStrip(
                                groupId: groupId,
                                memberCount: memberCount,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    right: -6,
                    top: -8,
                    child: GroupCardNotificationBadge(
                      pendingCount: pendingCount,
                    ),
                  ),
                  Positioned(
                    right: -6,
                    bottom: -6,
                    child: GroupStreakMedal(groupId: groupId),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class GroupCardNotificationBadge extends StatelessWidget {
  final int pendingCount;

  const GroupCardNotificationBadge({super.key, required this.pendingCount});

  @override
  Widget build(BuildContext context) {
    final hasPending = pendingCount > 0;

    if (!hasPending) return const SizedBox.shrink();

    return Container(
      constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
      padding: const EdgeInsets.symmetric(horizontal: 5),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: ssOrange,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: ssBg, width: 2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.075),
            blurRadius: 9,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Text(
        pendingCount > 9 ? '9+' : '$pendingCount',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w900,
          height: 1,
        ),
      ),
    );
  }
}

class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final TextEditingController nameController = TextEditingController();
  XFile? selectedGroupPhoto;
  String? selectedGroupEmoji;
  int selectedGroupColorValue = kGroupColorOptions.first.toARGB32();
  bool creating = false;

  @override
  void dispose() {
    nameController.dispose();
    super.dispose();
  }

  Future<void> _pickGroupPhoto() async {
    if (creating) return;

    try {
      final picker = image_picker.ImagePicker();
      final photo = await picker.pickImage(
        source: image_picker.ImageSource.gallery,
        imageQuality: 88,
        maxWidth: 1600,
      );

      if (!mounted || photo == null) return;

      setState(() {
        selectedGroupPhoto = photo;
        selectedGroupEmoji = null;
      });
    } catch (error) {
      if (!mounted) return;
      showSundaySnack(context, 'No se pudo abrir la galería: $error');
    }
  }

  Future<void> _selectEmoji() async {
    if (creating) return;

    final emoji = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => GroupEmojiPickerSheet(selectedEmoji: selectedGroupEmoji),
    );

    if (!mounted || emoji == null) return;

    setState(() {
      selectedGroupEmoji = emoji;
      selectedGroupPhoto = null;
    });
  }

  Future<void> _createGroup() async {
    final name = nameController.text.trim();
    if (name.isEmpty || creating) return;

    setState(() => creating = true);

    try {
      final createdGroup = await crearGrupoMinimo(
        nombreGrupo: name,
        groupPhoto: selectedGroupPhoto,
        groupEmoji: selectedGroupEmoji,
        groupColorValue: selectedGroupColorValue,
      );

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => GroupInviteReadyScreen(
            groupId: createdGroup.groupId,
            groupName: name,
            inviteCode: createdGroup.inviteCode,
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      showSundaySnack(context, 'Error: $error');
    } finally {
      if (mounted) setState(() => creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ssBg,
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(
              subtitle: 'Nuevo grupo',
              onBack: () => Navigator.pop(context),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: CreateGroupAvatarPicker(
                        photo: selectedGroupPhoto,
                        emoji: selectedGroupEmoji,
                        colorValue: selectedGroupColorValue,
                        name: nameController.text,
                        onTap: _pickGroupPhoto,
                      ),
                    ),
                    const SizedBox(height: 26),
                    const GroupCreationSectionLabel('FOTO O EMOTICONO'),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: CreateGroupSourceButton(
                            icon: Icons.image_outlined,
                            label: 'Galería',
                            onTap: _pickGroupPhoto,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: CreateGroupSourceButton(
                            emoji: '😀',
                            label: 'Emoticono',
                            onTap: _selectEmoji,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 28),
                    const GroupCreationSectionLabel('NOMBRE DEL GRUPO'),
                    const SizedBox(height: 10),
                    SundayTextField(
                      controller: nameController,
                      hintText: 'Ej: Los de siempre',
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _createGroup(),
                    ),
                    if (selectedGroupPhoto == null) ...[
                      const SizedBox(height: 24),
                      const GroupCreationSectionLabel('COLOR'),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 18,
                        runSpacing: 16,
                        children: kGroupColorOptions.map((color) {
                          final selected =
                              selectedGroupColorValue == color.toARGB32();
                          return GroupColorDot(
                            color: color,
                            selected: selected,
                            onTap: () => setState(
                              () => selectedGroupColorValue = color.toARGB32(),
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                    const SizedBox(height: 28),
                    const TimezoneInfoCard(),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
              child: AnimatedBuilder(
                animation: nameController,
                builder: (context, _) {
                  final enabled = nameController.text.trim().isNotEmpty;
                  return SundayButton(
                    text: creating ? 'Creando...' : 'Crear grupo',
                    onPressed: creating || !enabled ? null : _createGroup,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class GroupCreationSectionLabel extends StatelessWidget {
  final String text;

  const GroupCreationSectionLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: ssText2,
        fontSize: 12,
        letterSpacing: 0.8,
        fontWeight: FontWeight.w900,
      ),
    );
  }
}

class CreateGroupAvatarPicker extends StatelessWidget {
  final XFile? photo;
  final String? emoji;
  final int colorValue;
  final String name;
  final VoidCallback onTap;

  const CreateGroupAvatarPicker({
    super.key,
    required this.photo,
    required this.emoji,
    required this.colorValue,
    required this.name,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = groupColorFromValue(colorValue);
    final hasPhoto = photo != null;
    final resolvedEmoji = emoji ?? '👥';

    return GestureDetector(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 106,
            height: 106,
            decoration: BoxDecoration(
              color: hasPhoto ? null : color.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(28),
              border: hasPhoto
                  ? null
                  : Border.all(color: ssOrangeMid, width: 1.8),
            ),
            foregroundDecoration: hasPhoto
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: ssOrangeMid, width: 1.8),
                  )
                : null,
            clipBehavior: Clip.antiAlias,
            alignment: Alignment.center,
            child: hasPhoto
                ? Image.file(
                    File(photo!.path),
                    width: 106,
                    height: 106,
                    fit: BoxFit.cover,
                    alignment: Alignment.center,
                    filterQuality: FilterQuality.high,
                    errorBuilder: (_, _, _) => Text(
                      resolvedEmoji,
                      style: const TextStyle(fontSize: 34, height: 1),
                    ),
                  )
                : Text(
                    resolvedEmoji,
                    style: const TextStyle(fontSize: 34, height: 1),
                  ),
          ),
          Positioned(
            right: -6,
            bottom: -4,
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: ssTitle,
                shape: BoxShape.circle,
                border: Border.all(color: ssBg, width: 3),
              ),
              child: const Icon(
                Icons.photo_camera_outlined,
                color: Colors.white,
                size: 18,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class CreateGroupSourceButton extends StatelessWidget {
  final IconData? icon;
  final String? emoji;
  final String label;
  final VoidCallback onTap;

  const CreateGroupSourceButton({
    super.key,
    this.icon,
    this.emoji,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          height: 54,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: ssBorder),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (emoji != null)
                Text(emoji!, style: const TextStyle(fontSize: 18))
              else
                Icon(
                  icon ?? Icons.image_outlined,
                  color: ssOrangeDark,
                  size: 20,
                ),
              const SizedBox(width: 10),
              Text(
                label,
                style: const TextStyle(
                  color: ssTitle,
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class GroupColorDot extends StatelessWidget {
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  const GroupColorDot({
    super.key,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? Colors.black : Colors.white,
            width: selected ? 3 : 2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.10),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
      ),
    );
  }
}

class GroupEmojiPickerSheet extends StatefulWidget {
  final String? selectedEmoji;

  const GroupEmojiPickerSheet({super.key, this.selectedEmoji});

  @override
  State<GroupEmojiPickerSheet> createState() => _GroupEmojiPickerSheetState();
}

class _GroupEmojiPickerSheetState extends State<GroupEmojiPickerSheet> {
  late int selectedSectionIndex;

  @override
  void initState() {
    super.initState();
    selectedSectionIndex = _sectionIndexForEmoji(widget.selectedEmoji);
  }

  int _sectionIndexForEmoji(String? emoji) {
    final cleanEmoji = normalizarEmojiReaccion(emoji ?? '');
    if (cleanEmoji.isEmpty) return 0;

    for (var index = 0; index < kGroupEmojiSections.length; index++) {
      if (kGroupEmojiSections[index].emojis.contains(cleanEmoji)) {
        return index;
      }
    }

    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final height = math.min(MediaQuery.sizeOf(context).height * 0.76, 640.0);
    final section = kGroupEmojiSections[selectedSectionIndex];
    final selectedEmoji = normalizarEmojiReaccion(widget.selectedEmoji ?? '');

    return SafeArea(
      top: false,
      child: Container(
        height: height,
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                margin: const EdgeInsets.only(bottom: 18),
                decoration: BoxDecoration(
                  color: ssBorder,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const Text(
              'Elige un emoticono',
              style: TextStyle(
                color: ssTitle,
                fontSize: 19,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 46,
              child: ListView.separated(
                physics: const BouncingScrollPhysics(),
                scrollDirection: Axis.horizontal,
                itemCount: kGroupEmojiSections.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final option = kGroupEmojiSections[index];
                  final selected = index == selectedSectionIndex;

                  return Tooltip(
                    message: option.label,
                    child: InkWell(
                      onTap: () => setState(() {
                        selectedSectionIndex = index;
                      }),
                      borderRadius: BorderRadius.circular(15),
                      child: Container(
                        width: 44,
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: selected ? ssOrangeLight : ssBg,
                          borderRadius: BorderRadius.circular(15),
                          border: Border.all(
                            color: selected ? ssOrange : ssBorder,
                            width: selected ? 1.6 : 1,
                          ),
                        ),
                        child: Text(
                          option.icon,
                          style: const TextStyle(fontSize: 22, height: 1),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            Text(
              section.label,
              style: const TextStyle(
                color: ssText2,
                fontSize: 13,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final crossAxisCount = math.max(
                    6,
                    math.min(9, (constraints.maxWidth / 46).floor()),
                  );

                  return GridView.builder(
                    key: ValueKey(section.label),
                    physics: const BouncingScrollPhysics(),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: crossAxisCount,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                    ),
                    itemCount: section.emojis.length,
                    itemBuilder: (context, index) {
                      final emoji = section.emojis[index];
                      final selected = emoji == selectedEmoji;

                      return InkWell(
                        onTap: () => Navigator.pop(context, emoji),
                        borderRadius: BorderRadius.circular(14),
                        child: Container(
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: selected ? ssOrangeLight : ssBg,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: selected ? ssOrange : ssBorder,
                              width: selected ? 1.6 : 1,
                            ),
                          ),
                          child: Text(
                            emoji,
                            style: const TextStyle(fontSize: 24, height: 1),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class TimezoneInfoCard extends StatelessWidget {
  const TimezoneInfoCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: ssOrangeLight,
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Zona horaria automática',
            style: TextStyle(
              color: ssOrangeDark,
              fontSize: 14,
              fontWeight: FontWeight.w900,
            ),
          ),
          SizedBox(height: 4),
          Text(
            'Europe/Madrid — el domingo va de 00:00 a 23:59',
            style: TextStyle(
              color: ssText2,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class InviteInfoCard extends StatelessWidget {
  const InviteInfoCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: ssBorder),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: ssOrangeLight,
            child: Icon(Icons.lock_outline_rounded, color: ssOrange, size: 20),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Entrada con aprobación',
                  style: TextStyle(
                    color: ssTitle,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Quien use tu invitación enviará una solicitud. Tú decides si entra al grupo.',
                  style: TextStyle(
                    color: ssText2,
                    fontSize: 12,
                    height: 1.35,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class GroupInviteReadyIcon extends StatelessWidget {
  final String groupId;
  final String groupName;

  const GroupInviteReadyIcon({
    super.key,
    required this.groupId,
    required this.groupName,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('groups')
          .doc(groupId)
          .snapshots(),
      builder: (context, snapshot) {
        final data = snapshot.data?.data();
        return GroupIcon(
          name: groupName,
          photoUrl: data?['photoUrl'] as String?,
          emoji: data?['emoji'] as String?,
          colorValue: data?['colorValue'],
          size: 58,
        );
      },
    );
  }
}

class GroupInviteReadyScreen extends StatelessWidget {
  final String groupId;
  final String groupName;
  final String inviteCode;

  const GroupInviteReadyScreen({
    super.key,
    required this.groupId,
    required this.groupName,
    required this.inviteCode,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ssBg,
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(
              onBack: () => Navigator.pushReplacement(
                context,
                MaterialPageRoute(
                  builder: (_) => GroupScreen(groupId: groupId),
                ),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: GroupInviteReadyIcon(
                        groupId: groupId,
                        groupName: groupName,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      groupName,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: ssTitle,
                        fontSize: 30,
                        fontWeight: FontWeight.w900,
                        height: 1.1,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Grupo creado. Comparte la invitación para empezar.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: ssText2,
                        fontSize: 14,
                        height: 1.4,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 28),
                    InviteCodePreviewCard(inviteCode: inviteCode),
                    const SizedBox(height: 22),
                    GroupInviteActionButtons(
                      groupId: groupId,
                      groupName: groupName,
                      inviteCode: inviteCode,
                      isAdmin: false,
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 10, 24, 24),
              child: SundayButton(
                text: 'Entrar al grupo',
                onPressed: () => Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(
                    builder: (_) => GroupScreen(groupId: groupId),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class InviteCodePreviewCard extends StatelessWidget {
  final String inviteCode;

  const InviteCodePreviewCard({super.key, required this.inviteCode});

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: inviteCode));
    if (!context.mounted) return;
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => _copy(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [ssOrange, Color(0xFFF7C225)],
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(Icons.link_rounded, color: Colors.white),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Código de invitación',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    inviteCode,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.9),
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.copy_rounded, color: Colors.white),
          ],
        ),
      ),
    );
  }
}

class JoinGroupScreen extends StatefulWidget {
  final User user;
  final String? initialInviteInput;

  const JoinGroupScreen({
    super.key,
    required this.user,
    this.initialInviteInput,
  });

  @override
  State<JoinGroupScreen> createState() => _JoinGroupScreenState();
}

class _JoinGroupScreenState extends State<JoinGroupScreen> {
  final TextEditingController codeController = TextEditingController();
  bool joining = false;

  @override
  void initState() {
    super.initState();
    final initialInviteInput = widget.initialInviteInput?.trim();
    if (initialInviteInput != null && initialInviteInput.isNotEmpty) {
      codeController.text = initialInviteInput;
    }
  }

  @override
  void dispose() {
    codeController.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) {
      if (!mounted) return;
      showSundaySnack(context, 'No hay texto copiado');
      return;
    }

    codeController.text = text;
  }

  Future<void> _joinGroup() async {
    final input = codeController.text.trim();
    if (input.isEmpty || joining) return;

    final groupId = await resolverGroupIdDesdeInvitacion(input);
    if (groupId == null) {
      if (!mounted) return;
      showSundaySnack(context, 'Invitación no válida');
      return;
    }

    setState(() => joining = true);

    try {
      await solicitarEntradaAGrupo(groupId: groupId, inviteInput: input);

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => JoinRequestSentScreen(groupId: groupId),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      showSundaySnack(context, 'Error: $error');
    } finally {
      if (mounted) setState(() => joining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final openedFromInviteLink =
        widget.initialInviteInput?.trim().isNotEmpty == true;

    return Scaffold(
      backgroundColor: ssBg,
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(onBack: () => Navigator.pop(context)),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 14, 24, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      openedFromInviteLink
                          ? 'Solicitud de acceso'
                          : 'Unirme a un grupo',
                      style: TextStyle(
                        color: ssTitle,
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                        height: 1.1,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      openedFromInviteLink
                          ? 'Revisa el grupo antes de enviar tu solicitud.'
                          : 'Pega el enlace o escribe el código de invitación que te hayan enviado.',
                      style: TextStyle(
                        color: ssText2,
                        fontSize: 14,
                        height: 1.45,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (!openedFromInviteLink) ...[
                      const SizedBox(height: 28),
                      const Text(
                        'INVITACIÓN',
                        style: TextStyle(
                          color: ssText3,
                          fontSize: 12,
                          letterSpacing: 1.2,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 8),
                      SundayTextField(
                        controller: codeController,
                        hintText: 'sundayselfie.app/j/...',
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _joinGroup(),
                      ),
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: _pasteFromClipboard,
                          icon: const Icon(
                            Icons.content_paste_rounded,
                            size: 18,
                          ),
                          label: const Text('Pegar desde portapapeles'),
                          style: TextButton.styleFrom(
                            foregroundColor: ssOrange,
                            textStyle: const TextStyle(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ],
                    SizedBox(height: openedFromInviteLink ? 28 : 18),
                    AnimatedBuilder(
                      animation: codeController,
                      builder: (context, _) {
                        final input = codeController.text.trim();

                        if (input.isEmpty) {
                          return const JoinInstructionCard();
                        }

                        return FutureBuilder<String?>(
                          future: resolverGroupIdDesdeInvitacion(input),
                          builder: (context, snapshot) {
                            if (snapshot.connectionState ==
                                ConnectionState.waiting) {
                              return const JoinPreviewMessageCard(
                                icon: Icons.search_rounded,
                                title: 'Comprobando invitación',
                                message:
                                    'Estamos buscando el grupo asociado a este código.',
                              );
                            }

                            final groupId = snapshot.data;
                            if (groupId == null) {
                              return const InvalidInviteCard();
                            }

                            return JoinGroupPreviewCard(
                              groupId: groupId,
                              currentUid: widget.user.uid,
                            );
                          },
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 10, 24, 24),
              child: AnimatedBuilder(
                animation: codeController,
                builder: (context, _) {
                  final valid = normalizarEntradaInvitacion(
                    codeController.text,
                  ).isNotEmpty;
                  return SundayButton(
                    text: joining
                        ? 'Enviando solicitud...'
                        : 'Enviar solicitud de acceso',
                    onPressed: joining || !valid ? null : _joinGroup,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class JoinInstructionCard extends StatelessWidget {
  const JoinInstructionCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: ssBorder),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: ssOrangeLight,
            child: Icon(Icons.link_rounded, color: ssOrange, size: 20),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Puedes pegar un enlace completo o solo el código. El administrador tendrá que aceptar tu entrada.',
              style: TextStyle(
                color: ssText2,
                fontSize: 12.5,
                height: 1.35,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class InvalidInviteCard extends StatelessWidget {
  const InvalidInviteCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7F2),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFFFD7C2)),
      ),
      child: const Row(
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: Color(0xFFFFE5D6),
            child: Icon(
              Icons.error_outline_rounded,
              color: ssOrangeDark,
              size: 20,
            ),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'No reconozco esta invitación. Revisa que el enlace o código esté completo.',
              style: TextStyle(
                color: ssOrangeDark,
                fontSize: 12.5,
                height: 1.35,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class JoinGroupPreviewCard extends StatelessWidget {
  final String groupId;
  final String currentUid;

  const JoinGroupPreviewCard({
    super.key,
    required this.groupId,
    required this.currentUid,
  });

  @override
  Widget build(BuildContext context) {
    final groupRef = FirebaseFirestore.instance
        .collection('groups')
        .doc(groupId);

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: groupRef.snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: CircularProgressIndicator(color: ssOrange),
            ),
          );
        }

        if (snapshot.hasError) {
          return JoinPreviewMessageCard(
            icon: Icons.visibility_off_outlined,
            title: 'Invitación detectada',
            message:
                'No se puede previsualizar el grupo, pero puedes enviar la solicitud.',
          );
        }

        if (!snapshot.hasData || !snapshot.data!.exists) {
          return const JoinPreviewMessageCard(
            icon: Icons.search_off_rounded,
            title: 'Grupo no encontrado',
            message: 'La invitación puede haber caducado o estar mal copiada.',
          );
        }

        final data = snapshot.data!.data() ?? {};
        if (data['deleted'] == true) {
          return const JoinPreviewMessageCard(
            icon: Icons.block_rounded,
            title: 'Grupo no disponible',
            message: 'Este grupo ya no acepta nuevas solicitudes.',
          );
        }

        final name = (data['name'] ?? 'Grupo').toString();
        final memberCountRaw = data['memberCount'] ?? 0;
        final memberCount = memberCountRaw is int
            ? memberCountRaw
            : int.tryParse('$memberCountRaw') ?? 0;

        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: groupRef.collection('members').doc(currentUid).snapshots(),
          builder: (context, memberSnapshot) {
            final isMember = memberSnapshot.data?.exists ?? false;

            return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: groupRef
                  .collection('joinRequests')
                  .doc(currentUid)
                  .snapshots(),
              builder: (context, requestSnapshot) {
                final hasRequest = requestSnapshot.data?.exists ?? false;

                return Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: ssBorder),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.035),
                        blurRadius: 14,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      GroupIcon(
                        name: name,
                        photoUrl: data['photoUrl'] as String?,
                        emoji: data['emoji'] as String?,
                        colorValue: data['colorValue'],
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              formatGroupDisplayName(name),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: ssTitle,
                                fontSize: 18,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              formatMemberCount(memberCount),
                              style: const TextStyle(
                                color: ssText2,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 8),
                            JoinStatusPill(
                              label: isMember
                                  ? 'Ya eres miembro'
                                  : hasRequest
                                  ? 'Solicitud enviada'
                                  : 'Listo para solicitar entrada',
                              color: isMember || hasRequest
                                  ? ssText3
                                  : ssOrange,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

class JoinPreviewMessageCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;

  const JoinPreviewMessageCard({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: ssBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: ssOrangeLight,
            child: Icon(icon, color: ssOrange, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: ssTitle,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: const TextStyle(
                    color: ssText2,
                    fontSize: 12.5,
                    height: 1.35,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class JoinStatusPill extends StatelessWidget {
  final String label;
  final Color color;

  const JoinStatusPill({super.key, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class JoinRequestSentScreen extends StatelessWidget {
  final String groupId;

  const JoinRequestSentScreen({super.key, required this.groupId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ssBg,
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(onBack: () => Navigator.pop(context)),
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 86,
                        height: 86,
                        decoration: const BoxDecoration(
                          color: ssOrange,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.check_rounded,
                          color: Colors.white,
                          size: 44,
                        ),
                      ),
                      const SizedBox(height: 22),
                      const Text(
                        'Solicitud enviada',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: ssTitle,
                          fontSize: 28,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Cuando un administrador la acepte, el grupo aparecerá en tu pantalla de grupos.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: ssText2,
                          fontSize: 14,
                          height: 1.45,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 10, 24, 24),
              child: SundayButton(
                text: 'Volver a grupos',
                onPressed: () =>
                    Navigator.popUntil(context, (route) => route.isFirst),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class GroupScreen extends StatefulWidget {
  final String groupId;

  const GroupScreen({super.key, required this.groupId});

  @override
  State<GroupScreen> createState() => _GroupScreenState();
}

class _GroupScreenState extends State<GroupScreen> {
  String selectedWeekKey = '';
  bool showingAllWeeks = false;
  bool chatExpanded = false;
  double chatDragOffset = 0;
  String? lastViewedWriteMarker;
  late DocumentReference<Map<String, dynamic>> groupRef;
  late Stream<DocumentSnapshot<Map<String, dynamic>>> groupStream;
  late Stream<QuerySnapshot<Map<String, dynamic>>> weeksStream;
  String? memberStreamUid;
  Stream<DocumentSnapshot<Map<String, dynamic>>>? memberStream;

  @override
  void initState() {
    super.initState();
    configureGroupStreams();
  }

  @override
  void didUpdateWidget(covariant GroupScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.groupId != widget.groupId) {
      configureGroupStreams();
    }
  }

  void configureGroupStreams() {
    selectedWeekKey = '';
    showingAllWeeks = false;
    chatExpanded = false;
    chatDragOffset = 0;
    groupRef = FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.groupId);
    groupStream = groupRef.snapshots();
    weeksStream = groupRef
        .collection('weeks')
        .orderBy('createdAt', descending: true)
        .snapshots();
    memberStreamUid = null;
    memberStream = null;
  }

  void _scheduleMarkWeekViewed(String weekKey) {
    if (weekKey.isEmpty) return;

    final marker = '${widget.groupId}:$weekKey';
    if (lastViewedWriteMarker == marker) return;
    lastViewedWriteMarker = marker;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      unawaited(
        marcarGrupoSemanaVisto(
          groupId: widget.groupId,
          weekKey: weekKey,
        ).catchError((error) {
          logDebug('No se pudo marcar el grupo como visto: $error');
          if (mounted && lastViewedWriteMarker == marker) {
            lastViewedWriteMarker = null;
          }
        }),
      );
    });
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> streamForMember(String uid) {
    if (memberStreamUid != uid || memberStream == null) {
      memberStreamUid = uid;
      memberStream = groupRef.collection('members').doc(uid).snapshots();
    }

    return memberStream!;
  }

  void _setChatExpanded(bool expanded) {
    chatExpanded = expanded;
    chatDragOffset = 0;
  }

  void _handleChatDragOffsetChanged(double offset) {
    if (!mounted) return;
    final nextOffset = offset.isFinite ? math.max(0.0, offset) : 0.0;
    if ((chatDragOffset - nextOffset).abs() < 0.5) return;

    setState(() => chatDragOffset = nextOffset);
  }

  @override
  Widget build(BuildContext context) {
    SundayClockScope.watch(context);
    final currentUser = FirebaseAuth.instance.currentUser;
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;

    return Scaffold(
      backgroundColor: ssBg,
      resizeToAvoidBottomInset: true,
      bottomNavigationBar: currentUser == null || keyboardVisible
          ? null
          : SundayTabBar(
              selectedIndex: 0,
              onSelected: (index) {
                if (index == 0) {
                  Navigator.pop(context);
                  return;
                }

                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(
                    builder: (_) =>
                        SundayShell(user: currentUser, initialIndex: index),
                  ),
                  (_) => false,
                );
              },
            ),
      body: SafeArea(
        child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: groupStream,
          builder: (context, groupSnapshot) {
            if (groupSnapshot.connectionState == ConnectionState.waiting) {
              return const Center(
                child: CircularProgressIndicator(color: ssOrange),
              );
            }

            if (groupSnapshot.hasError) {
              return GroupUnavailableScreen(
                title: 'No se pudo abrir el grupo',
                message:
                    'Puede que ya no tengas acceso o que el grupo haya cambiado.',
                groupId: currentUser == null ? null : widget.groupId,
              );
            }

            if (!groupSnapshot.hasData || !groupSnapshot.data!.exists) {
              return GroupUnavailableScreen(
                title: 'Grupo no encontrado',
                message: 'Este grupo ya no está disponible.',
                groupId: currentUser == null ? null : widget.groupId,
              );
            }

            final groupData = groupSnapshot.data!.data()!;
            if (groupData['deleted'] == true) {
              return GroupUnavailableScreen(
                title: 'Grupo eliminado',
                message: 'Este grupo ya no está disponible.',
                groupId: currentUser == null ? null : widget.groupId,
              );
            }

            final groupName = groupData['name'] ?? 'Grupo';
            final memberCount = groupData['memberCount'] ?? 0;

            if (currentUser == null) {
              return const GroupUnavailableScreen(
                title: 'Inicia sesión',
                message: 'Necesitas iniciar sesión para abrir este grupo.',
              );
            }

            return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: streamForMember(currentUser.uid),
              builder: (context, memberSnapshot) {
                if (memberSnapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(color: ssOrange),
                  );
                }

                if (memberSnapshot.hasError ||
                    !(memberSnapshot.data?.exists ?? false)) {
                  return GroupUnavailableScreen(
                    title: 'Sin acceso al grupo',
                    message: 'Ya no perteneces a este grupo.',
                    groupId: widget.groupId,
                  );
                }

                return Column(
                  children: [
                    AppHeader(
                      subtitle: formatGroupDisplayName(groupName.toString()),
                      subtitleCenteredInBottomGap: true,
                      subtitleStyle: ssGroupHeaderSubtitleStyle,
                      logoTapToHome: false,
                      onBack: () => Navigator.pop(context),
                      right: GroupMembersHeaderButton(
                        groupId: widget.groupId,
                        currentUid: currentUser.uid,
                      ),
                    ),
                    GroupPendingRequestsShortcut(
                      groupId: widget.groupId,
                      currentUid: currentUser.uid,
                    ),
                    Expanded(
                      child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                        stream: weeksStream,
                        builder: (context, weeksSnapshot) {
                          final weekDocs = weeksSnapshot.data?.docs ?? [];
                          final total = memberCount is int
                              ? memberCount
                              : int.tryParse('$memberCount') ?? 0;
                          final weekKeys = obtenerWeekKeysCalendarioGrupo(
                            groupCreatedAt: groupData['createdAt'],
                            existingWeekKeys: weekDocs.map((d) => d.id),
                          );
                          final effectiveSelectedWeekKey =
                              resolverWeekKeySeleccionadaGrupo(
                                weekKeys: weekKeys,
                                selectedWeekKey: selectedWeekKey,
                              );
                          final weekDocsById = {
                            for (final doc in weekDocs) doc.id: doc,
                          };
                          final publishedWeekKeys =
                              weekDocs
                                  .where((doc) {
                                    final postCount = intFromValue(
                                      doc.data()['postCount'],
                                    );
                                    return postCount > 0 &&
                                        weekKeys.contains(doc.id);
                                  })
                                  .map((doc) => doc.id)
                                  .toList()
                                ..sort((a, b) {
                                  final aOrder = _weekKeyOrderValue(a) ?? 0;
                                  final bOrder = _weekKeyOrderValue(b) ?? 0;
                                  return bOrder.compareTo(aOrder);
                                });
                          final publishedWeeksSignature = publishedWeekKeys
                              .map((key) {
                                final postCount = intFromValue(
                                  weekDocsById[key]?.data()['postCount'],
                                );
                                return '$key:$postCount';
                              })
                              .join('|');
                          final calendarEntries =
                              construirEntradasCalendarioSemanas(
                                weekKeys: weekKeys,
                                weekDocs: weekDocs,
                                memberCount: total,
                              );
                          if (!showingAllWeeks) {
                            _scheduleMarkWeekViewed(effectiveSelectedWeekKey);
                          }

                          Widget weekSelector;
                          if (weeksSnapshot.hasError) {
                            weekSelector = const Padding(
                              padding: EdgeInsets.symmetric(vertical: 18),
                              child: Text(
                                'No se pudieron cargar las semanas del grupo',
                                style: TextStyle(color: ssText2),
                              ),
                            );
                          } else if (weekKeys.isEmpty) {
                            weekSelector = const SizedBox(height: 4);
                          } else {
                            final weekSelectorItems =
                                construirItemsSelectorSemanas(weekKeys);

                            weekSelector = SizedBox(
                              height: 33,
                              child: Row(
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      16,
                                      2,
                                      0,
                                      6,
                                    ),
                                    child: WeekCalendarButton(
                                      onTap: () async {
                                        final selected =
                                            await showWeekCalendarSheet(
                                              context: context,
                                              entries: calendarEntries,
                                              selectedWeekKey:
                                                  effectiveSelectedWeekKey,
                                            );

                                        if (!mounted || selected == null) {
                                          return;
                                        }

                                        setState(() {
                                          selectedWeekKey = selected;
                                          showingAllWeeks = false;
                                        });
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      0,
                                      2,
                                      0,
                                      6,
                                    ),
                                    child: WeekChip(
                                      key: ValueKey(
                                        'group_week_all_$showingAllWeeks',
                                      ),
                                      text: 'Todos',
                                      selected: showingAllWeeks,
                                      horizontalPadding: 10,
                                      onTap: () => setState(() {
                                        showingAllWeeks = true;
                                        _setChatExpanded(false);
                                      }),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Container(
                                    width: 1,
                                    height: 25,
                                    margin: const EdgeInsets.only(
                                      top: 2,
                                      bottom: 6,
                                    ),
                                    color: ssBorder,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        0,
                                        2,
                                        0,
                                        6,
                                      ),
                                      child: ClipRRect(
                                        borderRadius:
                                            const BorderRadius.horizontal(
                                              left: Radius.circular(999),
                                            ),
                                        child: SizedBox(
                                          height: 25,
                                          child: ListView.separated(
                                            scrollDirection: Axis.horizontal,
                                            padding: const EdgeInsets.fromLTRB(
                                              0,
                                              0,
                                              16,
                                              0,
                                            ),
                                            itemCount: weekSelectorItems.length,
                                            separatorBuilder: (_, _) =>
                                                const SizedBox(width: 6),
                                            itemBuilder: (context, index) {
                                              final item =
                                                  weekSelectorItems[index];
                                              if (item.startsWith('year:')) {
                                                return WeekYearSeparatorChip(
                                                  year: item.substring(5),
                                                );
                                              }

                                              final key = item.substring(5);
                                              final selected =
                                                  !showingAllWeeks &&
                                                  key ==
                                                      effectiveSelectedWeekKey;
                                              final label =
                                                  obtenerEtiquetaSemanaCorta(
                                                    key,
                                                  );
                                              return WeekChip(
                                                key: ValueKey(
                                                  'group_week_${key}_$selected',
                                                ),
                                                text: label,
                                                selected: selected,
                                                horizontalPadding: 13,
                                                onTap: () => setState(() {
                                                  selectedWeekKey = key;
                                                  showingAllWeeks = false;
                                                  chatDragOffset = 0;
                                                }),
                                              );
                                            },
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }

                          final keyboardChatOpen =
                              keyboardVisible && chatExpanded;
                          final allWeeksMode = showingAllWeeks;
                          final chatCanWrite =
                              effectiveSelectedWeekKey.isNotEmpty &&
                              esDomingo() &&
                              effectiveSelectedWeekKey ==
                                  obtenerWeekKeyActual();
                          final expandedChatHeight =
                              resolverAlturaPanelChatSemanal(
                                screenHeight: MediaQuery.sizeOf(context).height,
                                keyboardOpen: false,
                                canWrite: chatCanWrite,
                              );

                          return GroupWeeklyContentLayout(
                            keyboardVisible: keyboardVisible,
                            showChatPanel: !allWeeksMode,
                            chatExpanded: allWeeksMode ? false : chatExpanded,
                            chatDragOffset: allWeeksMode ? 0 : chatDragOffset,
                            expandedChatHeight: allWeeksMode
                                ? null
                                : expandedChatHeight,
                            weekSelector: weekSelector,
                            postsGrid: allWeeksMode
                                ? GroupAllPostsGrid(
                                    groupId: widget.groupId,
                                    groupName: groupName.toString(),
                                    groupPhotoUrl:
                                        groupData['photoUrl'] as String?,
                                    weekKeys: publishedWeekKeys,
                                    reloadSignature: publishedWeeksSignature,
                                  )
                                : GroupPostsGrid(
                                    groupId: widget.groupId,
                                    groupName: groupName.toString(),
                                    groupPhotoUrl:
                                        groupData['photoUrl'] as String?,
                                    weekKey: effectiveSelectedWeekKey,
                                  ),
                            chatPanel: allWeeksMode
                                ? const SizedBox.shrink()
                                : WeeklyChatPanel(
                                    groupId: widget.groupId,
                                    weekKey: effectiveSelectedWeekKey,
                                    expanded: chatExpanded,
                                    fillAvailableHeight: keyboardChatOpen,
                                    onDragOffsetChanged:
                                        _handleChatDragOffsetChanged,
                                    onToggle: () => setState(
                                      () => _setChatExpanded(!chatExpanded),
                                    ),
                                  ),
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class GroupWeeklyContentLayout extends StatelessWidget {
  final bool keyboardVisible;
  final bool showChatPanel;
  final bool chatExpanded;
  final double chatDragOffset;
  final double? expandedChatHeight;
  final Widget weekSelector;
  final Widget postsGrid;
  final Widget chatPanel;

  const GroupWeeklyContentLayout({
    super.key,
    required this.keyboardVisible,
    this.showChatPanel = true,
    required this.chatExpanded,
    this.chatDragOffset = 0,
    this.expandedChatHeight,
    required this.weekSelector,
    required this.postsGrid,
    required this.chatPanel,
  });

  @override
  Widget build(BuildContext context) {
    final keyboardChatOpen = showChatPanel && keyboardVisible && chatExpanded;

    if (keyboardChatOpen) {
      return Column(
        children: [
          weekSelector,
          Flexible(
            key: const ValueKey('weekly_chat_panel_slot'),
            fit: FlexFit.tight,
            child: chatPanel,
          ),
        ],
      );
    }

    return Column(
      children: [
        weekSelector,
        const SizedBox(height: 5),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final rawExpandedHeight = expandedChatHeight;
              final resolvedExpandedHeight =
                  rawExpandedHeight != null && rawExpandedHeight.isFinite
                  ? rawExpandedHeight
                  : kWeeklyChatCollapsedSlotHeight;
              final expandedInset = math.min(
                resolvedExpandedHeight,
                constraints.maxHeight,
              );
              final safeChatDragOffset = chatDragOffset.isFinite
                  ? math.max(0.0, chatDragOffset)
                  : 0.0;
              final bottomInset = !showChatPanel
                  ? 0.0
                  : chatExpanded
                  ? math.max(
                      kWeeklyChatCollapsedSlotHeight,
                      expandedInset - safeChatDragOffset,
                    )
                  : kWeeklyChatCollapsedSlotHeight;
              final draggingChatPanel =
                  showChatPanel && chatExpanded && safeChatDragOffset > 0;

              return Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  Positioned.fill(
                    child: AnimatedPadding(
                      duration: draggingChatPanel
                          ? Duration.zero
                          : kWeeklyChatPanelAnimationDuration,
                      curve: kWeeklyChatPanelAnimationCurve,
                      padding: EdgeInsets.only(bottom: bottomInset),
                      child: postsGrid,
                    ),
                  ),
                  if (showChatPanel)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: constraints.maxHeight,
                        ),
                        child: chatPanel,
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class GroupUnavailableScreen extends StatefulWidget {
  final String title;
  final String message;
  final String? groupId;

  const GroupUnavailableScreen({
    super.key,
    required this.title,
    required this.message,
    this.groupId,
  });

  @override
  State<GroupUnavailableScreen> createState() => _GroupUnavailableScreenState();
}

class _GroupUnavailableScreenState extends State<GroupUnavailableScreen> {
  bool removing = false;

  Future<void> _removeFromApp() async {
    final groupId = widget.groupId?.trim();
    if (groupId == null || groupId.isEmpty || removing) return;

    setState(() => removing = true);

    try {
      await eliminarGrupoDeLaApp(groupId: groupId);

      if (!mounted) return;
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        Navigator.pop(context);
        return;
      }

      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => SundayShell(user: user, initialIndex: 0),
        ),
        (_) => false,
      );
      final rootContext = sundayNavigatorKey.currentContext;
      if (rootContext != null && rootContext.mounted) {
        showSundaySnack(rootContext, 'Grupo eliminado de la app');
      }
    } catch (error) {
      if (!mounted) return;
      showSundaySnack(context, 'No se pudo eliminar el grupo: $error');
    } finally {
      if (mounted) setState(() => removing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canRemoveFromApp =
        widget.groupId != null && widget.groupId!.trim().isNotEmpty;

    return Column(
      children: [
        AppHeader(onBack: () => Navigator.pop(context)),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 78,
                  height: 78,
                  decoration: BoxDecoration(
                    color: ssOrangeLight,
                    borderRadius: BorderRadius.circular(26),
                  ),
                  child: const Icon(
                    Icons.notifications_off_outlined,
                    color: ssOrangeDark,
                    size: 36,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  widget.title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: ssTitle,
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: ssText2,
                    fontSize: 15,
                    height: 1.45,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 22),
                if (canRemoveFromApp) ...[
                  SundayButton(
                    text: removing
                        ? 'Eliminando...'
                        : 'Eliminar grupo de la app',
                    onPressed: removing ? null : _removeFromApp,
                  ),
                  const SizedBox(height: 10),
                ],
                SundayButton(
                  text: 'Volver',
                  variant: canRemoveFromApp
                      ? SundayButtonVariant.outline
                      : SundayButtonVariant.primary,
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class GroupMembersHeaderButton extends StatefulWidget {
  final String groupId;
  final String? currentUid;

  const GroupMembersHeaderButton({
    super.key,
    required this.groupId,
    required this.currentUid,
  });

  @override
  State<GroupMembersHeaderButton> createState() =>
      _GroupMembersHeaderButtonState();
}

class _GroupMembersHeaderButtonState extends State<GroupMembersHeaderButton> {
  Stream<DocumentSnapshot<Map<String, dynamic>>>? memberStream;
  late Stream<QuerySnapshot<Map<String, dynamic>>> requestsStream;

  @override
  void initState() {
    super.initState();
    configureStreams();
  }

  @override
  void didUpdateWidget(covariant GroupMembersHeaderButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.groupId != widget.groupId ||
        oldWidget.currentUid != widget.currentUid) {
      configureStreams();
    }
  }

  void configureStreams() {
    memberStream = widget.currentUid == null
        ? null
        : FirebaseFirestore.instance
              .collection('groups')
              .doc(widget.groupId)
              .collection('members')
              .doc(widget.currentUid!)
              .snapshots();
    requestsStream = FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.groupId)
        .collection('joinRequests')
        .snapshots();
  }

  void _openMembers(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GroupMembersScreen(groupId: widget.groupId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentMemberStream = memberStream;

    if (currentMemberStream == null) {
      return IconButton(
        onPressed: () => _openMembers(context),
        icon: const SundayHeaderMoreIcon(),
      );
    }

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: currentMemberStream,
      builder: (context, memberSnapshot) {
        final memberData = memberSnapshot.data?.data();
        final isAdmin = memberData?['role'] == 'admin';

        if (!isAdmin) {
          return IconButton(
            onPressed: () => _openMembers(context),
            icon: const SundayHeaderMoreIcon(),
          );
        }

        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: requestsStream,
          builder: (context, requestsSnapshot) {
            final pendingCount = requestsSnapshot.data?.docs.length ?? 0;

            return Stack(
              clipBehavior: Clip.none,
              children: [
                IconButton(
                  onPressed: () => _openMembers(context),
                  icon: const SundayHeaderMoreIcon(),
                ),
                if (pendingCount > 0)
                  Positioned(
                    right: 8,
                    top: 8,
                    child: Container(
                      constraints: const BoxConstraints(
                        minWidth: 17,
                        minHeight: 17,
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: ssOrange,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: ssBg, width: 2),
                      ),
                      child: Text(
                        pendingCount > 9 ? '9+' : '$pendingCount',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.w900,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

class GroupPendingRequestsShortcut extends StatefulWidget {
  final String groupId;
  final String currentUid;

  const GroupPendingRequestsShortcut({
    super.key,
    required this.groupId,
    required this.currentUid,
  });

  @override
  State<GroupPendingRequestsShortcut> createState() =>
      _GroupPendingRequestsShortcutState();
}

class _GroupPendingRequestsShortcutState
    extends State<GroupPendingRequestsShortcut> {
  late Stream<DocumentSnapshot<Map<String, dynamic>>> memberStream;
  late Stream<QuerySnapshot<Map<String, dynamic>>> requestsStream;

  @override
  void initState() {
    super.initState();
    configureStreams();
  }

  @override
  void didUpdateWidget(covariant GroupPendingRequestsShortcut oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.groupId != widget.groupId ||
        oldWidget.currentUid != widget.currentUid) {
      configureStreams();
    }
  }

  void configureStreams() {
    final groupRef = FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.groupId);
    memberStream = groupRef
        .collection('members')
        .doc(widget.currentUid)
        .snapshots();
    requestsStream = groupRef
        .collection('joinRequests')
        .orderBy('requestedAt', descending: true)
        .snapshots();
  }

  void _openMembers(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GroupMembersScreen(groupId: widget.groupId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: memberStream,
      builder: (context, memberSnapshot) {
        final memberData = memberSnapshot.data?.data();
        final isAdmin = memberData?['role'] == 'admin';

        if (!isAdmin) {
          return const SizedBox.shrink();
        }

        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: requestsStream,
          builder: (context, requestsSnapshot) {
            final requests = requestsSnapshot.data?.docs ?? [];

            if (requestsSnapshot.connectionState == ConnectionState.waiting) {
              return const SizedBox.shrink();
            }

            if (requests.isEmpty) {
              return const SizedBox.shrink();
            }

            final count = requests.length;

            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => _openMembers(context),
                  child: Ink(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: ssOrangeLight,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: ssOrangeMid),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration: const BoxDecoration(
                            color: ssOrange,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.person_add_alt_1_rounded,
                            color: Colors.white,
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                count == 1
                                    ? '1 solicitud pendiente'
                                    : '$count solicitudes pendientes',
                                style: const TextStyle(
                                  color: ssTitle,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              const SizedBox(height: 3),
                              const Text(
                                'Toca para revisar y aceptar entradas al grupo',
                                style: TextStyle(
                                  color: ssText2,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  height: 1.25,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Icon(
                          Icons.chevron_right_rounded,
                          color: ssOrange,
                          size: 26,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class GroupMembersScreen extends StatelessWidget {
  final String groupId;

  const GroupMembersScreen({super.key, required this.groupId});

  @override
  Widget build(BuildContext context) {
    final groupRef = FirebaseFirestore.instance
        .collection('groups')
        .doc(groupId);

    return Scaffold(
      backgroundColor: ssBg,
      body: SafeArea(
        child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: groupRef.snapshots(),
          builder: (context, groupSnapshot) {
            if (groupSnapshot.connectionState == ConnectionState.waiting) {
              return Column(
                children: [
                  AppHeader(onBack: () => Navigator.pop(context)),
                  const Expanded(
                    child: Center(
                      child: CircularProgressIndicator(color: ssOrange),
                    ),
                  ),
                ],
              );
            }

            if (groupSnapshot.hasError) {
              return Column(
                children: [
                  AppHeader(onBack: () => Navigator.pop(context)),
                  Expanded(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'Error cargando grupo: ${groupSnapshot.error}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: ssText2),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            }

            if (!groupSnapshot.hasData || !groupSnapshot.data!.exists) {
              return Column(
                children: [
                  AppHeader(onBack: () => Navigator.pop(context)),
                  const Expanded(
                    child: Center(child: Text('Grupo no encontrado')),
                  ),
                ],
              );
            }

            final groupData = groupSnapshot.data!.data() ?? {};
            final groupName = (groupData['name'] ?? 'Grupo').toString();
            final groupPhotoUrl = groupData['photoUrl'] as String?;
            final inviteCode = (groupData['inviteCode'] ?? '').toString();
            final inviteCodeVersionRaw = groupData['inviteCodeVersion'] ?? 1;
            final inviteCodeVersion = inviteCodeVersionRaw is int
                ? inviteCodeVersionRaw
                : int.tryParse('$inviteCodeVersionRaw') ?? 1;
            final activeWeeks = semanasActivasDesdeCreatedAt(
              groupData['createdAt'],
            );

            return Column(
              children: [
                AppHeader(
                  subtitle: formatGroupDisplayName(groupName),
                  subtitleCenteredInBottomGap: true,
                  subtitleStyle: ssGroupHeaderSubtitleStyle,
                  logoTapToHome: false,
                  onBack: () => Navigator.pop(context),
                ),
                Expanded(
                  child: GroupMembersHtmlContent(
                    groupId: groupId,
                    groupName: groupName,
                    groupPhotoUrl: groupPhotoUrl,
                    inviteCode: inviteCode,
                    inviteCodeVersion: inviteCodeVersion,
                    activeWeeks: activeWeeks,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class GroupMembersHtmlContent extends StatelessWidget {
  final String groupId;
  final String groupName;
  final String? groupPhotoUrl;
  final String inviteCode;
  final int inviteCodeVersion;
  final int activeWeeks;

  const GroupMembersHtmlContent({
    super.key,
    required this.groupId,
    required this.groupName,
    required this.groupPhotoUrl,
    required this.inviteCode,
    required this.inviteCodeVersion,
    required this.activeWeeks,
  });

  Future<void> _renameGroup(BuildContext context, bool isAdmin) async {
    if (!isAdmin) {
      showSundaySnack(
        context,
        'Solo los administradores pueden cambiar el nombre',
      );
      return;
    }

    final newName = await showDialog<String>(
      context: context,
      builder: (_) => GroupNameEditDialog(initialName: groupName),
    );

    if (newName == null || newName.trim().isEmpty) return;

    try {
      await actualizarNombreGrupo(groupId: groupId, newName: newName.trim());
      if (!context.mounted) return;
      showSundaySnack(context, 'Nombre del grupo actualizado');
    } catch (error) {
      if (!context.mounted) return;
      showSundaySnack(context, 'Error actualizando nombre: $error');
    }
  }

  Future<void> _changeGroupPhoto(BuildContext context, bool isAdmin) async {
    if (!isAdmin) {
      showSundaySnack(
        context,
        'Solo los administradores pueden cambiar la foto del grupo',
      );
      return;
    }

    try {
      final picker = image_picker.ImagePicker();
      final photo = await picker.pickImage(
        source: image_picker.ImageSource.gallery,
        imageQuality: 88,
        maxWidth: 1600,
      );

      if (photo == null || !context.mounted) return;

      showSundaySnack(context, 'Actualizando foto del grupo...');
      await actualizarFotoGrupo(groupId: groupId, foto: photo);

      if (!context.mounted) return;
      showSundaySnack(context, 'Foto del grupo actualizada');
    } catch (error) {
      if (!context.mounted) return;
      showSundaySnack(context, 'Error actualizando foto: $error');
    }
  }

  Future<void> _leaveGroup(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          title: const Text('Abandonar grupo'),
          content: Text(
            '¿Seguro que quieres abandonar ${formatGroupDisplayName(groupName)}?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancelar'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Abandonar'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !context.mounted) return;

    try {
      await abandonarGrupo(groupId: groupId);

      if (!context.mounted) return;
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        Navigator.popUntil(context, (route) => route.isFirst);
        return;
      }

      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => SundayShell(user: user, initialIndex: 0),
        ),
        (_) => false,
      );
      showSundaySnack(context, 'Has abandonado el grupo');
    } catch (error) {
      if (!context.mounted) return;
      showSundaySnack(context, 'Error abandonando grupo: $error');
    }
  }

  Future<void> _downloadSelfies(BuildContext context) async {
    final firestore = FirebaseFirestore.instance;
    final groupRef = firestore.collection('groups').doc(groupId);
    final groupSnapshot = await groupRef.get();
    final groupData = groupSnapshot.data() ?? const <String, dynamic>{};
    final memberCount = intFromValue(groupData['memberCount']);
    final weeksSnapshot = await groupRef
        .collection('weeks')
        .orderBy('createdAt', descending: true)
        .get();
    final weekKeys = obtenerWeekKeysCalendarioGrupo(
      groupCreatedAt: groupData['createdAt'],
      existingWeekKeys: weeksSnapshot.docs.map((doc) => doc.id),
    );
    final entries = construirEntradasCalendarioSemanas(
      weekKeys: weekKeys,
      weekDocs: weeksSnapshot.docs,
      memberCount: memberCount,
    );

    if (!context.mounted) return;

    final selectedWeekKeys = await showDownloadWeeksSheet(
      context: context,
      entries: entries,
    );

    if (!context.mounted) return;
    if (selectedWeekKeys == null || selectedWeekKeys.isEmpty) return;

    showSundaySnack(context, 'Guardando selfies...');
    try {
      final files = await descargarSelfiesGrupo(
        groupId: groupId,
        groupName: groupName,
        allWeeks: false,
        weekKeys: selectedWeekKeys,
      );

      if (!context.mounted) return;

      final savedCount = await guardarArchivosDescargadosEnTelefono(
        files: files,
      );

      if (!context.mounted) return;
      if (savedCount == 0) {
        showSundaySnack(context, 'No hay selfies para descargar');
      } else {
        showSundaySnack(
          context,
          savedCount == 1
              ? '1 selfie guardada en el teléfono'
              : '$savedCount selfies guardadas en el teléfono',
        );
      }
    } catch (error) {
      if (!context.mounted) return;
      showSundaySnack(context, mensajeErrorGuardandoArchivos(error));
    }
  }

  String get _inviteLink => crearEnlaceInvitacion(inviteCode);

  Future<void> _copyInviteCode(BuildContext context) async {
    final code = inviteCode.trim();
    if (code.isEmpty) {
      showSundaySnack(context, 'No hay invitación disponible todavía');
      return;
    }

    await Clipboard.setData(ClipboardData(text: code));
    if (!context.mounted) return;
    showSundaySnack(context, 'Código copiado');
  }

  void _shareInviteLink(BuildContext context) {
    final code = inviteCode.trim();
    if (code.isEmpty) {
      showSundaySnack(context, 'No hay invitación disponible todavía');
      return;
    }

    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? const Rect.fromLTWH(0, 0, 1, 1)
        : box.localToGlobal(Offset.zero) & box.size;

    unawaited(
      SharePlus.instance.share(
        ShareParams(
          text: 'Únete a mi grupo de Sunday Selfie: $_inviteLink',
          subject: 'Invitación a $groupName',
          sharePositionOrigin: origin,
        ),
      ),
    );
  }

  Future<void> _regenerateInvite(BuildContext context, bool isAdmin) async {
    if (!isAdmin) {
      showSundaySnack(
        context,
        'Solo los administradores pueden regenerar el código',
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          title: const Text('Regenerar invitación'),
          content: const Text(
            'El código anterior dejará de funcionar. Tendrás que compartir el nuevo código.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancelar'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Regenerar'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !context.mounted) return;

    try {
      await regenerarInvitacionGrupo(groupId: groupId);
      if (!context.mounted) return;
      showSundaySnack(context, 'Código de invitación regenerado');
    } catch (error) {
      if (!context.mounted) return;
      showSundaySnack(context, 'Error regenerando invitación: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    SundayClockScope.watch(context);
    final membersRef = FirebaseFirestore.instance
        .collection('groups')
        .doc(groupId)
        .collection('members');

    final postsRef = FirebaseFirestore.instance
        .collection('groups')
        .doc(groupId)
        .collection('weeks')
        .doc(obtenerWeekKeyActual())
        .collection('posts');

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: membersRef.snapshots(),
      builder: (context, membersSnapshot) {
        if (membersSnapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: ssOrange),
          );
        }

        if (membersSnapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'No se pudieron cargar los miembros: ${membersSnapshot.error}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: ssText2),
              ),
            ),
          );
        }

        final memberDocs = [...(membersSnapshot.data?.docs ?? [])];
        memberDocs.sort((a, b) {
          final aRole = (a.data()['role'] ?? 'member').toString();
          final bRole = (b.data()['role'] ?? 'member').toString();
          if (aRole != bRole) {
            if (aRole == 'admin') return -1;
            if (bRole == 'admin') return 1;
          }
          final aName = formatUserDisplayName(
            a.data()['effectiveName'] ?? '',
          ).toLowerCase();
          final bName = formatUserDisplayName(
            b.data()['effectiveName'] ?? '',
          ).toLowerCase();
          return aName.compareTo(bName);
        });

        final currentUid = FirebaseAuth.instance.currentUser?.uid;
        final currentMember = currentUid == null
            ? null
            : memberDocs.where((doc) => doc.id == currentUid).firstOrNull;
        final isCurrentAdmin = currentMember?.data()['role'] == 'admin';

        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: postsRef.snapshots(),
          builder: (context, postsSnapshot) {
            final postedUids = (postsSnapshot.data?.docs ?? [])
                .map((doc) => doc.id)
                .toSet();

            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
              children: [
                const MembersHtmlSectionLabel(text: 'INFORMACIÓN'),
                const SizedBox(height: 8),
                GroupInfoInlineRow(
                  icon: Icons.calendar_month_outlined,
                  label: 'Tiempo activo',
                  value: activeWeeks == 1 ? '1 semana' : '$activeWeeks semanas',
                ),
                const SizedBox(height: 24),
                if (isCurrentAdmin)
                  GroupJoinRequestsInlineSection(
                    groupId: groupId,
                    groupName: groupName,
                    groupPhotoUrl: groupPhotoUrl,
                    inviteCodeVersion: inviteCodeVersion,
                  ),
                if (isCurrentAdmin)
                  GroupBlockedUsersInlineSection(groupId: groupId),
                if (isCurrentAdmin)
                  GroupModerationReportsInlineSection(groupId: groupId),
                MembersHtmlSectionLabel(
                  text: 'MIEMBROS — ${memberDocs.length}',
                ),
                const SizedBox(height: 8),
                if (memberDocs.isEmpty)
                  const MembersInlineEmptyText(text: 'No hay miembros todavía.')
                else
                  ...memberDocs.map(
                    (doc) => GroupMemberHtmlRow(
                      groupId: groupId,
                      groupName: groupName,
                      groupPhotoUrl: groupPhotoUrl,
                      memberDoc: doc,
                      posted: postedUids.contains(doc.id),
                      currentUserIsAdmin: isCurrentAdmin,
                    ),
                  ),
                const SizedBox(height: 26),
                GroupOptionsSection(
                  title: 'AJUSTES DEL GRUPO',
                  rows: [
                    GroupOptionRow(
                      icon: GroupOptionIconKind.photo,
                      title: 'Foto',
                      onTap: () => _changeGroupPhoto(context, isCurrentAdmin),
                    ),
                    GroupOptionRow(
                      icon: GroupOptionIconKind.editName,
                      title: 'Nombre',
                      onTap: () => _renameGroup(context, isCurrentAdmin),
                    ),
                    GroupOptionRow(
                      icon: GroupOptionIconKind.download,
                      title: 'Descargar',
                      onTap: () => _downloadSelfies(context),
                    ),
                  ],
                ),
                const SizedBox(height: 28),
                GroupOptionsSection(
                  title: 'INVITAR AMIGOS',
                  rows: [
                    GroupOptionRow(
                      icon: GroupOptionIconKind.invite,
                      title: 'Invitar',
                      onTap: () => _shareInviteLink(context),
                    ),
                    GroupOptionRow(
                      icon: GroupOptionIconKind.code,
                      title: 'Código',
                      trailingText: inviteCode.trim().isEmpty
                          ? 'SIN CÓDIGO'
                          : inviteCode.trim(),
                      onTap: () => _copyInviteCode(context),
                    ),
                    if (isCurrentAdmin)
                      GroupOptionRow(
                        icon: GroupOptionIconKind.refresh,
                        title: 'Regenerar código',
                        onTap: () => _regenerateInvite(context, isCurrentAdmin),
                      ),
                  ],
                ),
                const SizedBox(height: 28),
                GroupOptionsSection(
                  rows: [
                    GroupOptionRow(
                      icon: GroupOptionIconKind.leave,
                      title: 'Salir',
                      destructive: true,
                      onTap: () => _leaveGroup(context),
                    ),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class GroupNameEditDialog extends StatefulWidget {
  final String initialName;

  const GroupNameEditDialog({super.key, required this.initialName});

  @override
  State<GroupNameEditDialog> createState() => _GroupNameEditDialogState();
}

class _GroupNameEditDialogState extends State<GroupNameEditDialog> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: formatGroupDisplayName(widget.initialName),
    );
    _focusNode = FocusNode();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _close([String? result]) {
    _focusNode.unfocus();
    Navigator.of(context).pop(result);
  }

  void _save() {
    final nextName = _controller.text.trim();
    if (nextName.isEmpty) return;
    _close(nextName);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      title: const Text('Cambiar nombre del grupo'),
      content: TextField(
        controller: _controller,
        focusNode: _focusNode,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _save(),
        decoration: const InputDecoration(hintText: 'Nombre del grupo'),
      ),
      actions: [
        TextButton(onPressed: () => _close(), child: const Text('Cancelar')),
        TextButton(onPressed: _save, child: const Text('Guardar')),
      ],
    );
  }
}

class GroupMemberNameEditDialog extends StatefulWidget {
  final String initialName;

  const GroupMemberNameEditDialog({super.key, required this.initialName});

  @override
  State<GroupMemberNameEditDialog> createState() =>
      _GroupMemberNameEditDialogState();
}

class _GroupMemberNameEditDialogState extends State<GroupMemberNameEditDialog> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: formatUserDisplayName(widget.initialName),
    );
    _focusNode = FocusNode();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _close([String? result]) {
    _focusNode.unfocus();
    Navigator.of(context).pop(result);
  }

  void _save() {
    final nextName = _controller.text.trim();
    if (nextName.isEmpty) return;
    _close(nextName);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      title: const Text('Cambiar nombre en este grupo'),
      content: TextField(
        controller: _controller,
        focusNode: _focusNode,
        autofocus: true,
        maxLength: 80,
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _save(),
        decoration: const InputDecoration(hintText: 'Tu nombre en este grupo'),
      ),
      actions: [
        TextButton(onPressed: () => _close(), child: const Text('Cancelar')),
        TextButton(onPressed: _save, child: const Text('Guardar')),
      ],
    );
  }
}

class MembersHtmlSectionLabel extends StatelessWidget {
  final String text;

  const MembersHtmlSectionLabel({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: ssText3,
        fontSize: 12,
        fontWeight: FontWeight.w900,
        letterSpacing: 1.1,
      ),
    );
  }
}

class GroupInfoInlineRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const GroupInfoInlineRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ssSeparator, width: 1.2),
      ),
      child: Row(
        children: [
          Icon(icon, color: ssOrangeDark, size: 21),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: ssText2,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: ssTitle,
              fontSize: 14,
              fontWeight: FontWeight.w900,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class MembersInlineEmptyText extends StatelessWidget {
  final String text;

  const MembersInlineEmptyText({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Text(
        text,
        style: const TextStyle(
          color: ssText3,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class GroupMemberHtmlRow extends StatelessWidget {
  final String groupId;
  final String groupName;
  final String? groupPhotoUrl;
  final QueryDocumentSnapshot<Map<String, dynamic>> memberDoc;
  final bool posted;
  final bool currentUserIsAdmin;

  const GroupMemberHtmlRow({
    super.key,
    required this.groupId,
    required this.groupName,
    required this.groupPhotoUrl,
    required this.memberDoc,
    required this.posted,
    required this.currentUserIsAdmin,
  });

  void _openAdminActions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => MemberActionsSheet(
        groupId: groupId,
        groupName: groupName,
        groupPhotoUrl: groupPhotoUrl,
        memberDoc: memberDoc,
        posted: posted,
        currentUserIsAdmin: true,
        showReminderControls: false,
        showSelfiesAction: true,
      ),
    );
  }

  void _openReminderActions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => MemberActionsSheet(
        groupId: groupId,
        groupName: groupName,
        groupPhotoUrl: groupPhotoUrl,
        memberDoc: memberDoc,
        posted: posted,
        currentUserIsAdmin: false,
        showReminderControls: true,
        showSelfiesAction: false,
      ),
    );
  }

  void _openOwnActions(
    BuildContext context, {
    required String memberName,
    required String? memberPhotoUrl,
  }) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => OwnMemberGroupOptionsSheet(
        groupId: groupId,
        groupName: groupName,
        groupPhotoUrl: groupPhotoUrl,
        memberUid: memberDoc.id,
        memberName: memberName,
        memberPhotoUrl: memberPhotoUrl,
      ),
    );
  }

  void _openMemberSelfies(
    BuildContext context, {
    required String memberName,
    required String? memberPhotoUrl,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GroupMemberSelfiesScreen(
          groupId: groupId,
          groupName: groupName,
          groupPhotoUrl: groupPhotoUrl,
          memberUid: memberDoc.id,
          memberName: memberName,
          memberPhotoUrl: memberPhotoUrl,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = memberDoc.data();
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    final name = formatUserDisplayName(data['effectiveName'] ?? 'Usuario');
    final role = (data['role'] ?? 'member').toString();
    final photoUrl = data['effectivePhotoUrl'] as String?;
    final isAdmin = role == 'admin';
    final isMe = memberDoc.id == currentUid;
    final showMissingPublicationStatus = debeMostrarMiembroSinPublicar(
      posted: posted,
    );
    final showPublicationStatus = posted || showMissingPublicationStatus;

    return InkWell(
      onTap: isMe
          ? () => _openOwnActions(
              context,
              memberName: name,
              memberPhotoUrl: photoUrl,
            )
          : currentUserIsAdmin
          ? () => _openAdminActions(context)
          : () => _openMemberSelfies(
              context,
              memberName: name,
              memberPhotoUrl: photoUrl,
            ),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: ssSeparator, width: 1)),
        ),
        child: Row(
          children: [
            MembersInitialAvatar(name: name, photoUrl: photoUrl, size: 44),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: isMe
                              ? () => _openOwnActions(
                                  context,
                                  memberName: name,
                                  memberPhotoUrl: photoUrl,
                                )
                              : currentUserIsAdmin
                              ? () => _openAdminActions(context)
                              : () => _openMemberSelfies(
                                  context,
                                  memberName: name,
                                  memberPhotoUrl: photoUrl,
                                ),
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: ssText,
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              height: 1.2,
                            ),
                          ),
                        ),
                      ),
                      if (isAdmin) ...[
                        const SizedBox(width: 8),
                        const MemberAdminBadge(),
                      ],
                    ],
                  ),
                  if (showPublicationStatus) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: posted
                                ? const Color(0xFFA8D8A8)
                                : ssSeparator,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          posted
                              ? 'Publicó esta semana'
                              : 'Aún no ha publicado',
                          style: TextStyle(
                            color: posted ? const Color(0xFF4CAF50) : ssText3,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (isMe)
              const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Tú',
                    style: TextStyle(
                      color: ssText3,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(width: 5),
                  Icon(Icons.edit_outlined, color: ssText3, size: 17),
                ],
              )
            else if (!posted && esDomingo())
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _openReminderActions(context),
                child: ReminderInlineBadge(
                  groupId: groupId,
                  weekKey: obtenerWeekKeyActual(),
                  targetUid: memberDoc.id,
                ),
              )
            else
              const Icon(Icons.chevron_right_rounded, color: ssText3, size: 22),
          ],
        ),
      ),
    );
  }
}

class GroupOptionsSection extends StatelessWidget {
  final String? title;
  final List<Widget> rows;

  const GroupOptionsSection({super.key, this.title, required this.rows});

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();

    final borderRadius = BorderRadius.circular(18);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null) ...[
          MembersHtmlSectionLabel(text: title!),
          const SizedBox(height: 8),
        ],
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: borderRadius,
            border: Border.all(color: ssBorder, width: 1.1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.028),
                blurRadius: 14,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: borderRadius,
            child: Material(
              color: Colors.transparent,
              child: Column(
                children: [
                  for (var index = 0; index < rows.length; index++) ...[
                    rows[index],
                    if (index != rows.length - 1)
                      const Divider(
                        height: 1,
                        thickness: 1,
                        color: ssSeparator,
                        indent: 76,
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

enum GroupOptionIconKind {
  photo,
  editName,
  download,
  invite,
  code,
  refresh,
  leave,
}

class GroupOptionRow extends StatelessWidget {
  final GroupOptionIconKind icon;
  final String title;
  final String? subtitle;
  final String? trailingText;
  final bool highlighted;
  final bool destructive;
  final VoidCallback onTap;

  const GroupOptionRow({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.trailingText,
    this.highlighted = false,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final dangerColor = const Color(0xFFD96558);
    final titleColor = destructive
        ? dangerColor
        : highlighted
        ? ssOrangeDark
        : ssText;
    final iconBackground = destructive
        ? const Color(0xFFFFF5F3)
        : highlighted
        ? ssOrangeLight
        : ssBg;
    final iconBorderColor = destructive
        ? const Color(0xFFF3C9C4)
        : highlighted
        ? ssOrangeMid
        : ssBorder;
    final iconColor = destructive ? dangerColor : ssOrangeDark;
    final chevronColor = destructive ? dangerColor : ssText3;

    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 9, 12, 9),
            child: Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: iconBackground,
                    borderRadius: BorderRadius.circular(15),
                    border: Border.all(color: iconBorderColor, width: 1.1),
                  ),
                  child: GroupOptionLineIcon(icon: icon, color: iconColor),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: titleColor,
                          fontSize: 15,
                          height: 1.15,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 3),
                        Text(
                          subtitle!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: ssText3,
                            fontSize: 12,
                            height: 1.2,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailingText != null) ...[
                  const SizedBox(width: 10),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 112),
                    child: Text(
                      trailingText!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        color: ssText3,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 6),
                Icon(
                  Icons.chevron_right_rounded,
                  color: chevronColor,
                  size: 24,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class GroupOptionLineIcon extends StatelessWidget {
  final GroupOptionIconKind icon;
  final Color color;
  final double size;

  const GroupOptionLineIcon({
    super.key,
    required this.icon,
    required this.color,
    this.size = 30,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _GroupOptionLineIconPainter(icon, color)),
    );
  }
}

class _GroupOptionLineIconPainter extends CustomPainter {
  final GroupOptionIconKind icon;
  final Color color;

  const _GroupOptionLineIconPainter(this.icon, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    final offset = Offset((size.width - side) / 2, (size.height - side) / 2);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.scale(side / 100);

    switch (icon) {
      case GroupOptionIconKind.photo:
        _paintPhoto(canvas, paint);
        break;
      case GroupOptionIconKind.editName:
        _paintPencil(canvas, paint);
        break;
      case GroupOptionIconKind.download:
        _paintDownload(canvas, paint);
        break;
      case GroupOptionIconKind.invite:
        _paintInvite(canvas, paint);
        break;
      case GroupOptionIconKind.code:
        _paintKey(canvas, paint);
        break;
      case GroupOptionIconKind.refresh:
        _paintRefresh(canvas, paint);
        break;
      case GroupOptionIconKind.leave:
        _paintLeave(canvas, paint);
        break;
    }

    canvas.restore();
  }

  void _paintPhoto(Canvas canvas, Paint paint) {
    final frame = RRect.fromRectAndRadius(
      const Rect.fromLTWH(14, 22, 72, 56),
      const Radius.circular(11),
    );
    canvas.drawRRect(frame, paint);
    canvas.drawCircle(const Offset(34, 40), 7, paint);

    final mountains = Path()
      ..moveTo(17, 70)
      ..lineTo(37, 51)
      ..lineTo(51, 64)
      ..lineTo(64, 48)
      ..lineTo(84, 68);
    canvas.drawPath(mountains, paint);
  }

  void _paintPencil(Canvas canvas, Paint paint) {
    final pencil = Path()
      ..moveTo(23, 76)
      ..lineTo(31, 55)
      ..lineTo(69, 17)
      ..quadraticBezierTo(75, 11, 81, 17)
      ..lineTo(83, 19)
      ..quadraticBezierTo(89, 25, 83, 31)
      ..lineTo(45, 69)
      ..close();
    canvas.drawPath(pencil, paint);
    canvas.drawLine(const Offset(67, 19), const Offset(81, 33), paint);
    canvas.drawLine(const Offset(31, 55), const Offset(45, 69), paint);
  }

  void _paintDownload(Canvas canvas, Paint paint) {
    canvas.drawLine(const Offset(50, 18), const Offset(50, 58), paint);

    final arrow = Path()
      ..moveTo(32, 42)
      ..lineTo(50, 60)
      ..lineTo(68, 42);
    canvas.drawPath(arrow, paint);

    final tray = Path()
      ..moveTo(22, 62)
      ..lineTo(22, 75)
      ..quadraticBezierTo(22, 82, 29, 82)
      ..lineTo(71, 82)
      ..quadraticBezierTo(78, 82, 78, 75)
      ..lineTo(78, 62);
    canvas.drawPath(tray, paint);
  }

  void _paintInvite(Canvas canvas, Paint paint) {
    final plane = Path()
      ..moveTo(14, 42)
      ..lineTo(86, 17)
      ..lineTo(63, 82)
      ..lineTo(49, 56)
      ..close();
    canvas.drawPath(plane, paint);
    canvas.drawLine(const Offset(49, 56), const Offset(86, 17), paint);
  }

  void _paintKey(Canvas canvas, Paint paint) {
    canvas.drawCircle(const Offset(34, 60), 13, paint);
    canvas.drawLine(const Offset(45, 51), const Offset(77, 19), paint);
    canvas.drawLine(const Offset(62, 34), const Offset(74, 46), paint);
    canvas.drawLine(const Offset(70, 26), const Offset(82, 38), paint);
  }

  void _paintRefresh(Canvas canvas, Paint paint) {
    canvas.drawArc(
      const Rect.fromLTWH(24, 24, 52, 52),
      -math.pi * 0.18,
      math.pi * 1.55,
      false,
      paint,
    );

    final arrowHead = Path()
      ..moveTo(70, 28)
      ..lineTo(81, 24)
      ..lineTo(79, 36);
    canvas.drawPath(arrowHead, paint);
  }

  void _paintLeave(Canvas canvas, Paint paint) {
    final door = Path()
      ..moveTo(43, 20)
      ..lineTo(27, 20)
      ..quadraticBezierTo(19, 20, 19, 28)
      ..lineTo(19, 72)
      ..quadraticBezierTo(19, 80, 27, 80)
      ..lineTo(43, 80);
    canvas.drawPath(door, paint);

    canvas.drawLine(const Offset(45, 50), const Offset(84, 50), paint);
    final arrow = Path()
      ..moveTo(68, 34)
      ..lineTo(84, 50)
      ..lineTo(68, 66);
    canvas.drawPath(arrow, paint);
  }

  @override
  bool shouldRepaint(covariant _GroupOptionLineIconPainter oldDelegate) {
    return oldDelegate.icon != icon || oldDelegate.color != color;
  }
}

class OwnMemberGroupOptionsSheet extends StatefulWidget {
  final String groupId;
  final String groupName;
  final String? groupPhotoUrl;
  final String memberUid;
  final String memberName;
  final String? memberPhotoUrl;

  const OwnMemberGroupOptionsSheet({
    super.key,
    required this.groupId,
    required this.groupName,
    required this.groupPhotoUrl,
    required this.memberUid,
    required this.memberName,
    required this.memberPhotoUrl,
  });

  @override
  State<OwnMemberGroupOptionsSheet> createState() =>
      _OwnMemberGroupOptionsSheetState();
}

class _OwnMemberGroupOptionsSheetState
    extends State<OwnMemberGroupOptionsSheet> {
  bool saving = false;

  Future<void> _changeName() async {
    if (saving) return;

    final newName = await showDialog<String>(
      context: context,
      builder: (_) => GroupMemberNameEditDialog(initialName: widget.memberName),
    );

    if (newName == null || newName.trim().isEmpty) return;

    final trimmedName = newName.trim();
    if (trimmedName == widget.memberName.trim()) return;

    setState(() => saving = true);

    try {
      await actualizarNombreEnGrupo(
        groupId: widget.groupId,
        newName: trimmedName,
      );

      if (!mounted) return;
      Navigator.pop(context);
      showSundaySnack(context, 'Nombre actualizado sólo en este grupo');
    } catch (error) {
      if (!mounted) return;
      showSundaySnack(context, 'Error actualizando nombre: $error');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  void _openSelfies() {
    final navigator = Navigator.of(context);
    navigator.pop();
    navigator.push(
      MaterialPageRoute(
        builder: (_) => GroupMemberSelfiesScreen(
          groupId: widget.groupId,
          groupName: widget.groupName,
          groupPhotoUrl: widget.groupPhotoUrl,
          memberUid: widget.memberUid,
          memberName: widget.memberName,
          memberPhotoUrl: widget.memberPhotoUrl,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: ssBorder,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            Row(
              children: [
                MembersInitialAvatar(
                  name: widget.memberName,
                  photoUrl: widget.memberPhotoUrl,
                  size: 44,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.memberName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: ssText,
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'Tu nombre dentro de este grupo',
                        style: TextStyle(
                          color: ssText3,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            InviteActionButton(
              text: saving ? 'Guardando...' : 'Cambiar nombre en este grupo',
              variant: InviteActionButtonVariant.primary,
              onTap: saving ? () {} : _changeName,
            ),
            const SizedBox(height: 8),
            InviteActionButton(
              text: 'Ver mis selfies en este grupo',
              variant: InviteActionButtonVariant.secondary,
              onTap: _openSelfies,
            ),
          ],
        ),
      ),
    );
  }
}

class ReminderInlineBadge extends StatelessWidget {
  final String groupId;
  final String weekKey;
  final String targetUid;

  const ReminderInlineBadge({
    super.key,
    required this.groupId,
    required this.weekKey,
    required this.targetUid,
  });

  @override
  Widget build(BuildContext context) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid;

    if (currentUid == null) {
      return const Icon(Icons.chevron_right_rounded, color: ssText3, size: 22);
    }

    final targetRemindersRef = FirebaseFirestore.instance
        .collection('groups')
        .doc(groupId)
        .collection('weeks')
        .doc(weekKey)
        .collection('reminders')
        .where('targetUid', isEqualTo: targetUid)
        .limit(1);

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: targetRemindersRef.snapshots(),
      builder: (context, snapshot) {
        final sent = snapshot.data?.docs.isNotEmpty ?? false;

        if (sent) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: ssOrangeLight,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: ssOrangeMid),
            ),
            child: const Text(
              'Zumbido\nenviado',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: ssOrangeDark,
                fontSize: 9,
                height: 1.05,
                fontWeight: FontWeight.w900,
              ),
            ),
          );
        }

        return Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: ssOrangeLight,
            shape: BoxShape.circle,
            border: Border.all(color: ssOrangeMid),
          ),
          child: const Icon(
            Icons.notifications_active_outlined,
            color: ssOrangeDark,
            size: 18,
          ),
        );
      },
    );
  }
}

class MembersInitialAvatar extends StatelessWidget {
  final String name;
  final String? photoUrl;
  final double size;

  const MembersInitialAvatar({
    super.key,
    required this.name,
    this.photoUrl,
    this.size = 44,
  });

  @override
  Widget build(BuildContext context) {
    return MiniProfileAvatar(name: name, photoUrl: photoUrl, size: size);
  }
}

class MemberAdminBadge extends StatelessWidget {
  const MemberAdminBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: ssOrangeLight,
        borderRadius: BorderRadius.circular(999),
      ),
      child: const Text(
        'Admin',
        style: TextStyle(
          color: ssOrangeDark,
          fontSize: 11,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class GroupJoinRequestsInlineSection extends StatelessWidget {
  final String groupId;
  final String groupName;
  final String? groupPhotoUrl;
  final int inviteCodeVersion;

  const GroupJoinRequestsInlineSection({
    super.key,
    required this.groupId,
    required this.groupName,
    required this.groupPhotoUrl,
    required this.inviteCodeVersion,
  });

  @override
  Widget build(BuildContext context) {
    final requestsRef = FirebaseFirestore.instance
        .collection('groups')
        .doc(groupId)
        .collection('joinRequests')
        .orderBy('requestedAt', descending: true);

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: requestsRef.snapshots(),
      builder: (context, snapshot) {
        final requests = snapshot.data?.docs ?? [];

        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox.shrink();
        }

        if (requests.isEmpty) {
          return const SizedBox.shrink();
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MembersHtmlSectionLabel(text: 'SOLICITUDES — ${requests.length}'),
            const SizedBox(height: 8),
            ...requests.map(
              (doc) => GroupJoinRequestHtmlRow(
                groupId: groupId,
                requestDoc: doc,
                groupName: groupName,
                groupPhotoUrl: groupPhotoUrl,
                inviteCodeVersion: inviteCodeVersion,
              ),
            ),
            const SizedBox(height: 22),
          ],
        );
      },
    );
  }
}

class GroupBlockedUsersInlineSection extends StatelessWidget {
  final String groupId;

  const GroupBlockedUsersInlineSection({super.key, required this.groupId});

  @override
  Widget build(BuildContext context) {
    final blockedUsersRef = FirebaseFirestore.instance
        .collection('groups')
        .doc(groupId)
        .collection('blockedUsers');

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: blockedUsersRef.snapshots(),
      builder: (context, snapshot) {
        final blockedUsers = snapshot.data?.docs ?? [];

        if (snapshot.connectionState == ConnectionState.waiting ||
            blockedUsers.isEmpty) {
          return const SizedBox.shrink();
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MembersHtmlSectionLabel(
              text: 'EXPULSADOS — ${blockedUsers.length}',
            ),
            const SizedBox(height: 8),
            ...blockedUsers.map(
              (doc) => GroupBlockedUserHtmlRow(
                groupId: groupId,
                blockedUserDoc: doc,
              ),
            ),
            const SizedBox(height: 22),
          ],
        );
      },
    );
  }
}

class GroupModerationReportsInlineSection extends StatefulWidget {
  final String groupId;

  const GroupModerationReportsInlineSection({super.key, required this.groupId});

  @override
  State<GroupModerationReportsInlineSection> createState() =>
      _GroupModerationReportsInlineSectionState();
}

class _GroupModerationReportsInlineSectionState
    extends State<GroupModerationReportsInlineSection> {
  bool loading = true;
  String? error;
  String? resolvingReportId;
  String? resolvingDecision;
  List<ModerationReport> reports = [];

  @override
  void initState() {
    super.initState();
    _loadReports(showLoading: false);
  }

  @override
  void didUpdateWidget(
    covariant GroupModerationReportsInlineSection oldWidget,
  ) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.groupId != widget.groupId) {
      _loadReports();
    }
  }

  Future<void> _loadReports({bool showLoading = true}) async {
    if (showLoading) {
      setState(() {
        loading = true;
        error = null;
      });
    }

    try {
      final nextReports = await listarReportesGrupo(groupId: widget.groupId);

      if (!mounted) return;
      setState(() {
        reports = nextReports;
        loading = false;
        error = null;
      });
    } catch (loadError) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = loadError.toString();
      });
    }
  }

  void _openReport(ModerationReport report) {
    if (!report.postExists || report.imageUrl.isEmpty) {
      showSundaySnack(context, 'Esta selfie ya no está disponible');
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SelfieFullScreen(
          groupId: report.groupId,
          weekKey: report.weekKey,
          postUid: report.postUid,
          post: {
            'uid': report.postUid,
            'authorName': report.authorName,
            'authorPhotoUrl': report.authorPhotoUrl,
            'imageUrl': report.imageUrl,
            'thumbUrl': report.thumbUrl,
          },
        ),
      ),
    );
  }

  Future<bool> _confirmRemoval(ModerationReport report) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          title: const Text('Retirar selfie reportada'),
          content: Text(
            'La selfie de ${report.authorName} dejará de verse en el grupo y el reporte quedará resuelto.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancelar'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text(
                'Retirar selfie',
                style: TextStyle(
                  color: Color(0xFFE74C3C),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        );
      },
    );

    return confirmed == true;
  }

  Future<void> _resolveReport(ModerationReport report, String decision) async {
    if (resolvingReportId != null) return;

    if (decision == kModerationDecisionRemoveSelfie) {
      final confirmed = await _confirmRemoval(report);
      if (!confirmed || !mounted) return;
    }

    setState(() {
      resolvingReportId = report.reportId;
      resolvingDecision = decision;
    });

    try {
      await resolverReporteGrupo(reportId: report.reportId, decision: decision);

      if (!mounted) return;
      showSundaySnack(
        context,
        decision == kModerationDecisionRemoveSelfie
            ? 'Selfie retirada del grupo'
            : 'Reporte marcado como revisado',
      );
      await _loadReports(showLoading: false);
    } catch (resolveError) {
      if (!mounted) return;
      showSundaySnack(context, 'Error resolviendo reporte: $resolveError');
    } finally {
      if (mounted) {
        setState(() {
          resolvingReportId = null;
          resolvingDecision = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading && reports.isEmpty) {
      return const SizedBox.shrink();
    }

    if (error != null && reports.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const MembersHtmlSectionLabel(text: 'REPORTES'),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: ssBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'No se pudieron cargar los reportes: $error',
                  style: const TextStyle(
                    color: ssText2,
                    fontSize: 13,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => _loadReports(),
                  child: const Text('Reintentar'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
        ],
      );
    }

    if (reports.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MembersHtmlSectionLabel(text: 'REPORTES — ${reports.length}'),
        const SizedBox(height: 8),
        const Text(
          'Solo los administradores pueden verlos. La persona que reportó permanece privada.',
          style: TextStyle(
            color: ssText3,
            fontSize: 12,
            height: 1.35,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        ...reports.map((report) {
          final busy = resolvingReportId == report.reportId;
          return GroupModerationReportCard(
            report: report,
            busy: busy,
            resolvingDecision: busy ? resolvingDecision : null,
            onOpen: () => _openReport(report),
            onDismiss: () => _resolveReport(report, kModerationDecisionDismiss),
            onRemove: () =>
                _resolveReport(report, kModerationDecisionRemoveSelfie),
          );
        }),
        const SizedBox(height: 22),
      ],
    );
  }
}

class GroupModerationReportCard extends StatelessWidget {
  final ModerationReport report;
  final bool busy;
  final String? resolvingDecision;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;
  final VoidCallback onRemove;

  const GroupModerationReportCard({
    super.key,
    required this.report,
    required this.busy,
    required this.resolvingDecision,
    required this.onOpen,
    required this.onDismiss,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final dateLabel = report.createdAt == null
        ? ''
        : ' · ${formatShortDate(report.createdAt)}';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: ssBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onOpen,
            borderRadius: BorderRadius.circular(14),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    width: 58,
                    height: 58,
                    color: ssOrangeLight,
                    child: report.postExists && report.thumbUrl.isNotEmpty
                        ? CachedRemoteImage(
                            imageUrl: report.thumbUrl,
                            cacheVariant: 'thumbnail',
                            fit: BoxFit.cover,
                            errorWidget: const Icon(
                              Icons.broken_image_outlined,
                              color: ssOrangeDark,
                            ),
                          )
                        : const Icon(
                            Icons.hide_image_outlined,
                            color: ssOrangeDark,
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        report.authorName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: ssText,
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${report.reasonLabel} · ${obtenerEtiquetaSemana(report.weekKey)}$dateLabel',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: ssText2,
                          fontSize: 12,
                          height: 1.25,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (!report.postExists) ...[
                        const SizedBox(height: 3),
                        const Text(
                          'La selfie ya no está disponible',
                          style: TextStyle(
                            color: ssText3,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.chevron_right_rounded, color: ssText3),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: busy ? null : onDismiss,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: ssText,
                    side: const BorderSide(color: ssBorder),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    busy && resolvingDecision == kModerationDecisionDismiss
                        ? 'Guardando...'
                        : 'Mantener',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: busy ? null : onRemove,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFE74C3C),
                    side: const BorderSide(color: Color(0xFFF3C5C0)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    busy && resolvingDecision == kModerationDecisionRemoveSelfie
                        ? 'Retirando...'
                        : 'Retirar',
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class GroupBlockedUserHtmlRow extends StatefulWidget {
  final String groupId;
  final QueryDocumentSnapshot<Map<String, dynamic>> blockedUserDoc;

  const GroupBlockedUserHtmlRow({
    super.key,
    required this.groupId,
    required this.blockedUserDoc,
  });

  @override
  State<GroupBlockedUserHtmlRow> createState() =>
      _GroupBlockedUserHtmlRowState();
}

class _GroupBlockedUserHtmlRowState extends State<GroupBlockedUserHtmlRow> {
  bool allowingRejoin = false;

  Future<void> _allowRejoin(String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Permitir nueva solicitud'),
        content: Text(
          '$name podrá volver a solicitar entrada usando una invitación válida.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Permitir'),
          ),
        ],
      ),
    );

    if (confirmed != true || allowingRejoin) return;

    setState(() => allowingRejoin = true);

    try {
      await permitirReingresoGrupo(
        groupId: widget.groupId,
        targetUid: widget.blockedUserDoc.id,
      );
      if (!mounted) return;
      showSundaySnack(context, '$name puede volver a solicitar entrada');
    } catch (error) {
      if (!mounted) return;
      showSundaySnack(context, 'Error: $error');
    } finally {
      if (mounted) setState(() => allowingRejoin = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.blockedUserDoc.data();
    final name = formatUserDisplayName(data['effectiveName'] ?? 'Usuario');
    final photoUrl = data['effectivePhotoUrl'] as String?;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: ssSeparator, width: 1)),
      ),
      child: Row(
        children: [
          MembersInitialAvatar(name: name, photoUrl: photoUrl, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              name,
              style: const TextStyle(
                color: ssText,
                fontSize: 14,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          TextButton(
            onPressed: allowingRejoin ? null : () => _allowRejoin(name),
            child: Text(allowingRejoin ? '...' : 'Permitir'),
          ),
        ],
      ),
    );
  }
}

class GroupJoinRequestHtmlRow extends StatefulWidget {
  final String groupId;
  final QueryDocumentSnapshot<Map<String, dynamic>> requestDoc;
  final String groupName;
  final String? groupPhotoUrl;
  final int inviteCodeVersion;

  const GroupJoinRequestHtmlRow({
    super.key,
    required this.groupId,
    required this.requestDoc,
    required this.groupName,
    required this.groupPhotoUrl,
    required this.inviteCodeVersion,
  });

  @override
  State<GroupJoinRequestHtmlRow> createState() =>
      _GroupJoinRequestHtmlRowState();
}

class _GroupJoinRequestHtmlRowState extends State<GroupJoinRequestHtmlRow> {
  bool accepting = false;
  bool rejecting = false;

  Future<void> _acceptRequest() async {
    if (accepting) return;

    final requestUid = widget.requestDoc.id;

    setState(() => accepting = true);

    try {
      await aceptarSolicitudEntrada(
        groupId: widget.groupId,
        requestUid: requestUid,
      );

      if (!mounted) return;
      showSundaySnack(context, 'Solicitud aceptada');
    } catch (error) {
      if (!mounted) return;
      showSundaySnack(context, 'Error: $error');
    } finally {
      if (mounted) setState(() => accepting = false);
    }
  }

  Future<void> _rejectRequest() async {
    if (rejecting) return;

    setState(() => rejecting = true);

    try {
      await rechazarSolicitudEntrada(
        groupId: widget.groupId,
        requestUid: widget.requestDoc.id,
      );

      if (!mounted) return;
      showSundaySnack(context, 'Solicitud rechazada');
    } catch (error) {
      if (!mounted) return;
      showSundaySnack(context, 'Error: $error');
    } finally {
      if (mounted) setState(() => rejecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.requestDoc.data();
    final requestName = (data['baseName'] ?? 'Usuario').toString();
    final rawRequestPhoto = data['basePhotoUrl'];
    final requestPhoto =
        rawRequestPhoto is String && rawRequestPhoto.trim().isNotEmpty
        ? rawRequestPhoto.trim()
        : null;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: ssSeparator, width: 1)),
      ),
      child: Row(
        children: [
          MembersInitialAvatar(
            name: requestName,
            photoUrl: requestPhoto,
            size: 44,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              requestName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: ssText,
                fontSize: 15,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          TextButton(
            onPressed: rejecting ? null : _rejectRequest,
            child: Text(rejecting ? '...' : 'Rechazar'),
          ),
          TextButton(
            onPressed: accepting ? null : _acceptRequest,
            child: Text(accepting ? '...' : 'Aceptar'),
          ),
        ],
      ),
    );
  }
}

class GroupInviteActionButtons extends StatelessWidget {
  final String groupId;
  final String groupName;
  final String inviteCode;
  final bool isAdmin;

  const GroupInviteActionButtons({
    super.key,
    required this.groupId,
    required this.groupName,
    required this.inviteCode,
    required this.isAdmin,
  });

  String get inviteLink => crearEnlaceInvitacion(inviteCode);

  Future<void> _copy(BuildContext context, String value) async {
    if (value.trim().isEmpty) {
      showSundaySnack(context, 'No hay invitación disponible todavía');
      return;
    }

    await Clipboard.setData(ClipboardData(text: value));
    if (!context.mounted) return;
  }

  Future<void> _openShareSheet(BuildContext context) async {
    final text = 'Únete a mi grupo de Sunday Selfie: $inviteLink';
    await SharePlus.instance.share(
      ShareParams(
        text: text,
        subject: 'Invitación a $groupName',
        sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1),
      ),
    );
  }

  Future<void> _regenerateInvite(BuildContext context) async {
    if (!isAdmin) {
      showSundaySnack(
        context,
        'Solo los administradores pueden regenerar el código',
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          title: const Text('Regenerar invitación'),
          content: const Text(
            'El código anterior dejará de funcionar. Tendrás que compartir el nuevo código.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancelar'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Regenerar'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !context.mounted) return;

    try {
      await regenerarInvitacionGrupo(groupId: groupId);
      if (!context.mounted) return;
      showSundaySnack(context, 'Código de invitación regenerado');
    } catch (error) {
      if (!context.mounted) return;
      showSundaySnack(context, 'Error regenerando invitación: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InviteActionButton(
          text: '📤 Enviar enlace de invitación',
          variant: InviteActionButtonVariant.primary,
          onTap: () => _openShareSheet(context),
        ),
        const SizedBox(height: 10),
        InviteActionButton(
          text: '🔑 Copiar código de invitación',
          variant: InviteActionButtonVariant.outline,
          onTap: () => _copy(context, inviteCode.trim()),
        ),
        if (isAdmin) ...[
          const SizedBox(height: 10),
          InviteActionButton(
            text: '🔄 Regenerar código',
            variant: InviteActionButtonVariant.outline,
            onTap: () => _regenerateInvite(context),
          ),
        ],
      ],
    );
  }
}

enum InviteActionButtonVariant { primary, secondary, outline }

class InviteActionButton extends StatelessWidget {
  final String text;
  final InviteActionButtonVariant variant;
  final VoidCallback onTap;

  const InviteActionButton({
    super.key,
    required this.text,
    required this.variant,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isPrimary = variant == InviteActionButtonVariant.primary;
    final isSecondary = variant == InviteActionButtonVariant.secondary;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          height: 56,
          decoration: BoxDecoration(
            color: isPrimary
                ? ssOrange
                : isSecondary
                ? ssOrangeLight
                : Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: isPrimary ? null : Border.all(color: ssBorder),
          ),
          child: Center(
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isPrimary
                    ? Colors.white
                    : isSecondary
                    ? ssOrangeDark
                    : ssText,
                fontSize: 15,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class InviteShareSheet extends StatelessWidget {
  final String groupName;
  final String inviteLink;
  final BuildContext feedbackContext;
  final VoidCallback onCopyLink;

  const InviteShareSheet({
    super.key,
    required this.groupName,
    required this.inviteLink,
    required this.feedbackContext,
    required this.onCopyLink,
  });

  @override
  Widget build(BuildContext context) {
    final options = const [
      ('💬', 'WhatsApp', Color(0xFF25D366), Colors.white),
      ('✉️', 'Mensajes', Color(0xFF34C759), Colors.white),
      ('✈️', 'Telegram', Color(0xFF229ED9), Colors.white),
      ('📷', 'Instagram', Color(0xFFE65D85), Colors.white),
      ('📧', 'Correo', Color(0xFF5B8DEF), Colors.white),
      ('•••', 'Más', ssOrangeLight, ssOrangeDark),
    ];

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        decoration: const BoxDecoration(
          color: Color(0xFFF2F2F7),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: ssBorder,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [ssOrange, Color(0xFFF7B733)],
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text('📸', style: TextStyle(fontSize: 22)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Únete a "$groupName"',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: ssTitle,
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          inviteLink,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: ssText3,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            GridView.count(
              crossAxisCount: 4,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 14,
              crossAxisSpacing: 14,
              childAspectRatio: 0.82,
              children: options.map((option) {
                return InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () {
                    Navigator.pop(context);
                    if (feedbackContext.mounted) {
                      showSundaySnack(
                        feedbackContext,
                        option.$2 == 'Más'
                            ? 'Compartiendo…'
                            : 'Compartido por ${option.$2}',
                      );
                    }
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: option.$3,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          option.$1,
                          style: TextStyle(color: option.$4, fontSize: 22),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        option.$2,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: ssText2,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 18),
            InviteSheetButton(
              text: 'Copiar enlace',
              onTap: () {
                Navigator.pop(context);
                onCopyLink();
              },
            ),
            const SizedBox(height: 8),
            InviteSheetButton(
              text: 'Cancelar',
              muted: true,
              onTap: () => Navigator.pop(context),
            ),
          ],
        ),
      ),
    );
  }
}

class InviteSheetButton extends StatelessWidget {
  final String text;
  final VoidCallback onTap;
  final bool muted;

  const InviteSheetButton({
    super.key,
    required this.text,
    required this.onTap,
    this.muted = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          height: 48,
          child: Center(
            child: Text(
              text,
              style: TextStyle(
                color: muted ? ssText3 : ssText,
                fontSize: 15,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MemberActionsSheet extends StatefulWidget {
  final String groupId;
  final String groupName;
  final String? groupPhotoUrl;
  final QueryDocumentSnapshot<Map<String, dynamic>> memberDoc;
  final bool posted;
  final bool currentUserIsAdmin;
  final bool showReminderControls;
  final bool showSelfiesAction;

  const MemberActionsSheet({
    super.key,
    required this.groupId,
    required this.groupName,
    required this.groupPhotoUrl,
    required this.memberDoc,
    required this.posted,
    required this.currentUserIsAdmin,
    this.showReminderControls = true,
    this.showSelfiesAction = false,
  });

  @override
  State<MemberActionsSheet> createState() => _MemberActionsSheetState();
}

class _MemberActionsSheetState extends State<MemberActionsSheet> {
  bool sendingReminder = false;
  bool preparingExtraReminder = false;
  bool extraReminderUnlocked = false;

  Future<void> _sendReminder() async {
    if (sendingReminder) return;

    setState(() => sendingReminder = true);

    try {
      await enviarZumbidoSelfie(
        groupId: widget.groupId,
        targetUid: widget.memberDoc.id,
        rewardedAdWatched: extraReminderUnlocked,
      );

      if (!mounted) return;
      Navigator.pop(context);
      showSundaySnack(context, 'Zumbido enviado');
    } catch (error) {
      if (!mounted) return;
      showSundaySnack(context, 'Error: $error');
    } finally {
      if (mounted) setState(() => sendingReminder = false);
    }
  }

  Future<void> _prepareExtraReminder() async {
    if (preparingExtraReminder) return;

    setState(() => preparingExtraReminder = true);

    try {
      final unlocked = await prepararZumbidoExtraConAnuncio(context);
      if (!mounted) return;
      if (unlocked) {
        setState(() => extraReminderUnlocked = true);
      }
    } catch (error) {
      if (!mounted) return;
      showSundaySnack(context, 'Error: $error');
    } finally {
      if (mounted) setState(() => preparingExtraReminder = false);
    }
  }

  Future<void> _makeAdmin(String name) async {
    try {
      await hacerAdministradorMiembro(
        groupId: widget.groupId,
        targetUid: widget.memberDoc.id,
      );
      if (!mounted) return;
      Navigator.pop(context);
      showSundaySnack(context, '$name ahora es administrador');
    } catch (error) {
      if (!mounted) return;
      showSundaySnack(context, 'Error: $error');
    }
  }

  Future<void> _removeMember(String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Expulsar usuario'),
        content: Text('¿Quieres expulsar a $name del grupo?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Expulsar'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await expulsarMiembroGrupo(
        groupId: widget.groupId,
        targetUid: widget.memberDoc.id,
      );
      if (!mounted) return;
      Navigator.pop(context);
      showSundaySnack(context, '$name expulsado del grupo');
    } catch (error) {
      if (!mounted) return;
      showSundaySnack(context, 'Error: $error');
    }
  }

  void _openSelfies(String name, String? photoUrl) {
    final navigator = Navigator.of(context);
    navigator.pop();
    navigator.push(
      MaterialPageRoute(
        builder: (_) => GroupMemberSelfiesScreen(
          groupId: widget.groupId,
          groupName: widget.groupName,
          groupPhotoUrl: widget.groupPhotoUrl,
          memberUid: widget.memberDoc.id,
          memberName: name,
          memberPhotoUrl: photoUrl,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    SundayClockScope.watch(context);
    final data = widget.memberDoc.data();
    final name = formatUserDisplayName(data['effectiveName'] ?? 'Usuario');
    final photoUrl = data['effectivePhotoUrl'] as String?;
    final role = (data['role'] ?? 'member').toString();
    final isAdmin = role == 'admin';
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    final showReminderSection =
        widget.showReminderControls && (widget.posted || esDomingo());
    final targetRemindersRef = FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.groupId)
        .collection('weeks')
        .doc(obtenerWeekKeyActual())
        .collection('reminders')
        .where('targetUid', isEqualTo: widget.memberDoc.id)
        .limit(1);

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: ssBorder,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            Row(
              children: [
                MembersInitialAvatar(name: name, photoUrl: photoUrl, size: 44),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: ssText,
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        isAdmin ? 'Administrador' : 'Miembro',
                        style: const TextStyle(
                          color: ssText3,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (showReminderSection) ...[
              if (!widget.posted && esDomingo()) ...[
                if (currentUid == null)
                  const SizedBox.shrink()
                else
                  StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: targetRemindersRef.snapshots(),
                    builder: (context, snapshot) {
                      final targetAlreadyReminded =
                          snapshot.data?.docs.isNotEmpty ?? false;
                      final needsAd =
                          targetAlreadyReminded && !extraReminderUnlocked;
                      final busy = sendingReminder || preparingExtraReminder;

                      return InviteActionButton(
                        text: busy
                            ? preparingExtraReminder
                                  ? 'Cargando anuncio...'
                                  : 'Enviando zumbido...'
                            : needsAd
                            ? 'Zumbido enviado'
                            : 'Enviar zumbido',
                        variant: needsAd && !busy
                            ? InviteActionButtonVariant.secondary
                            : InviteActionButtonVariant.primary,
                        onTap: busy
                            ? () {}
                            : needsAd
                            ? _prepareExtraReminder
                            : _sendReminder,
                      );
                    },
                  ),
                const SizedBox(height: 8),
                Text(
                  extraReminderUnlocked
                      ? 'El anuncio ya terminó. Puedes enviar otro zumbido.'
                      : 'Le recordaremos que todavía falta su Sunday Selfie de esta semana.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: ssText3,
                    fontSize: 12,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 16),
              ] else if (widget.posted) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF2FAF2),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFD8EED8)),
                  ),
                  child: const Row(
                    children: [
                      Icon(
                        Icons.check_circle_outline_rounded,
                        color: Color(0xFF4CAF50),
                        size: 20,
                      ),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Ya publicó esta semana',
                          style: TextStyle(
                            color: Color(0xFF4CAF50),
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              const Divider(height: 1, color: ssBorder),
              const SizedBox(height: 16),
            ],
            if (widget.showSelfiesAction)
              InviteActionButton(
                text: 'Ver sus selfies en este grupo',
                variant: InviteActionButtonVariant.primary,
                onTap: () => _openSelfies(name, photoUrl),
              ),
            if (widget.showSelfiesAction &&
                widget.currentUserIsAdmin &&
                !isAdmin)
              const SizedBox(height: 8),
            if (widget.currentUserIsAdmin && !isAdmin)
              InviteActionButton(
                text: '⬆️ Hacer administrador',
                variant: InviteActionButtonVariant.secondary,
                onTap: () => _makeAdmin(name),
              ),
            if (widget.currentUserIsAdmin && !isAdmin)
              const SizedBox(height: 8),
            if (widget.currentUserIsAdmin && !isAdmin)
              InviteActionButton(
                text: '🚫 Expulsar del grupo',
                variant: InviteActionButtonVariant.outline,
                onTap: () => _removeMember(name),
              ),
          ],
        ),
      ),
    );
  }
}

Color memberAvatarColor(String seed) {
  const colors = [
    ssOrange,
    Color(0xFF64B5F6),
    Color(0xFFA8D8A8),
    Color(0xFFCDB7F6),
    Color(0xFFF8BBD0),
    Color(0xFFFFD966),
    Color(0xFF9ADBE8),
    Color(0xFFF7C59F),
  ];

  final value = seed.codeUnits.fold<int>(0, (total, code) => total + code);
  return colors[value % colors.length];
}

class GroupPostsGrid extends StatefulWidget {
  final String groupId;
  final String groupName;
  final String? groupPhotoUrl;
  final String weekKey;

  const GroupPostsGrid({
    super.key,
    required this.groupId,
    required this.groupName,
    required this.groupPhotoUrl,
    required this.weekKey,
  });

  @override
  State<GroupPostsGrid> createState() => _GroupPostsGridState();
}

class _GroupPostsGridState extends State<GroupPostsGrid> {
  Stream<QuerySnapshot<Map<String, dynamic>>>? postsStream;
  Stream<QuerySnapshot<Map<String, dynamic>>>? membersStream;

  @override
  void initState() {
    super.initState();
    configureStreams();
  }

  @override
  void didUpdateWidget(covariant GroupPostsGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.groupId != widget.groupId ||
        oldWidget.weekKey != widget.weekKey) {
      configureStreams();
    }
  }

  void configureStreams() {
    if (widget.weekKey.isEmpty) {
      postsStream = null;
      membersStream = null;
      return;
    }

    final groupRef = FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.groupId);
    postsStream = groupRef
        .collection('weeks')
        .doc(widget.weekKey)
        .collection('posts')
        .orderBy('updatedAt', descending: true)
        .snapshots();
    membersStream = groupRef.collection('members').orderBy('role').snapshots();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.weekKey.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Aún no hay semanas publicadas en este grupo.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: ssText3,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );
    }

    final currentPostsStream = postsStream;
    final currentMembersStream = membersStream;

    if (currentPostsStream == null || currentMembersStream == null) {
      return const SizedBox.shrink();
    }

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: currentPostsStream,
      builder: (context, postsSnapshot) {
        if (postsSnapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: ssOrange),
          );
        }

        if (postsSnapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Error cargando selfies: ${postsSnapshot.error}',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        final postDocs = postsSnapshot.data?.docs ?? [];
        for (final postDoc in postDocs) {
          prefetchPostPhotoCache(postDoc.data(), includeOriginal: true);
        }
        final postedUids = postDocs.map((d) => d.id).toSet();

        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: currentMembersStream,
          builder: (context, membersSnapshot) {
            final memberDocs = membersSnapshot.data?.docs ?? [];
            final missingMembers = memberDocs
                .where((m) => !postedUids.contains(m.id))
                .toList();

            return CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                  sliver: SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          childAspectRatio: 0.56,
                        ),
                    delegate: SliverChildBuilderDelegate((context, index) {
                      if (index < postDocs.length) {
                        final doc = postDocs[index];
                        final post = doc.data();
                        return SelfieTile(
                          groupId: widget.groupId,
                          groupName: widget.groupName,
                          groupPhotoUrl: widget.groupPhotoUrl,
                          weekKey: widget.weekKey,
                          postUid: doc.id,
                          post: post,
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => SelfieFullScreen(
                                  groupId: widget.groupId,
                                  groupName: widget.groupName,
                                  groupPhotoUrl: widget.groupPhotoUrl,
                                  weekKey: widget.weekKey,
                                  postUid: doc.id,
                                  post: post,
                                  initialIndex: index,
                                  galleryEntries: postDocs.map((postDoc) {
                                    return SelfieViewerEntry(
                                      groupId: widget.groupId,
                                      groupName: widget.groupName,
                                      groupPhotoUrl: widget.groupPhotoUrl,
                                      weekKey: widget.weekKey,
                                      postUid: postDoc.id,
                                      post: postDoc.data(),
                                    );
                                  }).toList(),
                                ),
                              ),
                            );
                          },
                        );
                      }

                      final missingDoc =
                          missingMembers[index - postDocs.length];
                      final missing = missingDoc.data();
                      final name = formatUserDisplayName(
                        missing['effectiveName'] ?? 'Usuario',
                      );
                      final photoUrl = missing['effectivePhotoUrl'] as String?;
                      return MissingSelfieTile(
                        groupId: widget.groupId,
                        groupName: widget.groupName,
                        groupPhotoUrl: widget.groupPhotoUrl,
                        weekKey: widget.weekKey,
                        targetUid: missingDoc.id,
                        name: name,
                        photoUrl: photoUrl,
                        joinedAt: missing['joinedAt'],
                      );
                    }, childCount: postDocs.length + missingMembers.length),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class GroupPublishedSelfieEntry {
  final String weekKey;
  final String postUid;
  final Map<String, dynamic> post;

  const GroupPublishedSelfieEntry({
    required this.weekKey,
    required this.postUid,
    required this.post,
  });

  DateTime? get publishedAt =>
      timestampToDate(post['updatedAt']) ?? timestampToDate(post['createdAt']);

  SelfieViewerEntry toViewerEntry({
    required String groupId,
    required String groupName,
    required String? groupPhotoUrl,
  }) {
    return SelfieViewerEntry(
      groupId: groupId,
      groupName: groupName,
      groupPhotoUrl: groupPhotoUrl,
      weekKey: weekKey,
      postUid: postUid,
      post: post,
    );
  }
}

int compareGroupPublishedSelfiesNewest(
  GroupPublishedSelfieEntry a,
  GroupPublishedSelfieEntry b,
) {
  final dateA = a.publishedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
  final dateB = b.publishedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
  final dateCompare = dateB.compareTo(dateA);
  if (dateCompare != 0) return dateCompare;

  final weekCompare = (_weekKeyOrderValue(b.weekKey) ?? 0).compareTo(
    _weekKeyOrderValue(a.weekKey) ?? 0,
  );
  if (weekCompare != 0) return weekCompare;

  return a.postUid.compareTo(b.postUid);
}

class GroupAllPostsGrid extends StatefulWidget {
  final String groupId;
  final String groupName;
  final String? groupPhotoUrl;
  final List<String> weekKeys;
  final String reloadSignature;

  const GroupAllPostsGrid({
    super.key,
    required this.groupId,
    required this.groupName,
    required this.groupPhotoUrl,
    required this.weekKeys,
    required this.reloadSignature,
  });

  @override
  State<GroupAllPostsGrid> createState() => _GroupAllPostsGridState();
}

class _GroupAllPostsGridState extends State<GroupAllPostsGrid> {
  late Future<List<GroupPublishedSelfieEntry>> postsFuture;

  @override
  void initState() {
    super.initState();
    configureFuture();
  }

  @override
  void didUpdateWidget(covariant GroupAllPostsGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.groupId != widget.groupId ||
        oldWidget.reloadSignature != widget.reloadSignature ||
        !listEquals(oldWidget.weekKeys, widget.weekKeys)) {
      configureFuture();
    }
  }

  void configureFuture() {
    postsFuture = _loadPublishedPosts();
  }

  Future<List<GroupPublishedSelfieEntry>> _loadPublishedPosts() async {
    if (widget.weekKeys.isEmpty) return const [];

    final groupRef = FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.groupId);
    final entries = <GroupPublishedSelfieEntry>[];

    for (final weekKey in widget.weekKeys) {
      try {
        final postsSnapshot = await groupRef
            .collection('weeks')
            .doc(weekKey)
            .collection('posts')
            .get();

        for (final postDoc in postsSnapshot.docs) {
          final post = postDoc.data();
          prefetchPostPhotoCache(post, includeOriginal: true);
          entries.add(
            GroupPublishedSelfieEntry(
              weekKey: weekKey,
              postUid: postDoc.id,
              post: post,
            ),
          );
        }
      } catch (error) {
        logDebug('No se pudieron cargar selfies de $weekKey: $error');
      }
    }

    entries.sort(compareGroupPublishedSelfiesNewest);
    return entries;
  }

  void _openSelfie(
    BuildContext context,
    GroupPublishedSelfieEntry entry,
    List<GroupPublishedSelfieEntry> entries,
  ) {
    final initialIndex = entries.indexWhere(
      (candidate) =>
          candidate.weekKey == entry.weekKey &&
          candidate.postUid == entry.postUid,
    );

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SelfieFullScreen(
          groupId: widget.groupId,
          groupName: widget.groupName,
          groupPhotoUrl: widget.groupPhotoUrl,
          weekKey: entry.weekKey,
          postUid: entry.postUid,
          post: entry.post,
          initialIndex: initialIndex < 0 ? 0 : initialIndex,
          galleryEntries: entries
              .map(
                (candidate) => candidate.toViewerEntry(
                  groupId: widget.groupId,
                  groupName: widget.groupName,
                  groupPhotoUrl: widget.groupPhotoUrl,
                ),
              )
              .toList(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<GroupPublishedSelfieEntry>>(
      future: postsFuture,
      builder: (context, snapshot) {
        final loading = snapshot.connectionState == ConnectionState.waiting;

        if (loading) {
          return const Center(
            child: CircularProgressIndicator(color: ssOrange),
          );
        }

        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Error cargando selfies: ${snapshot.error}',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        final entries = snapshot.data ?? const <GroupPublishedSelfieEntry>[];
        if (entries.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Aún no hay selfies publicados en este grupo.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: ssText3,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          );
        }

        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 0.56,
                ),
                delegate: SliverChildBuilderDelegate((context, index) {
                  final entry = entries[index];
                  return SelfieTile(
                    groupId: widget.groupId,
                    groupName: widget.groupName,
                    groupPhotoUrl: widget.groupPhotoUrl,
                    weekKey: entry.weekKey,
                    postUid: entry.postUid,
                    post: entry.post,
                    onTap: () => _openSelfie(context, entry, entries),
                  );
                }, childCount: entries.length),
              ),
            ),
          ],
        );
      },
    );
  }
}

const double kGroupWeekSelectorKeyboardReserveHeight = 33.0;
const double kWeeklyChatCollapsedSlotHeight = 60.0;
const Duration kWeeklyChatPanelAnimationDuration = Duration(milliseconds: 240);
const Curve kWeeklyChatPanelAnimationCurve = Curves.easeOutCubic;
const double kWeeklyChatDragDismissDistance = 24.0;
const double kWeeklyChatDragDismissVelocity = 320.0;

double resolverAlturaPanelChatSemanal({
  required double screenHeight,
  required bool keyboardOpen,
  required bool canWrite,
  double? maxExpandedHeight,
}) {
  final targetHeight = math.min(
    screenHeight * (keyboardOpen ? 0.34 : 0.43),
    keyboardOpen ? 292.0 : (canWrite ? 356.0 : 326.0),
  );

  final availableHeight = maxExpandedHeight;
  if (availableHeight == null || !availableHeight.isFinite) {
    return targetHeight;
  }

  return math.max(0.0, math.min(targetHeight, availableHeight));
}

class WeeklyChatPanel extends StatefulWidget {
  final String groupId;
  final String weekKey;
  final bool expanded;
  final double? maxExpandedHeight;
  final bool fillAvailableHeight;
  final ValueChanged<double>? onDragOffsetChanged;
  final VoidCallback onToggle;

  const WeeklyChatPanel({
    super.key,
    required this.groupId,
    required this.weekKey,
    required this.expanded,
    this.maxExpandedHeight,
    this.fillAvailableHeight = false,
    this.onDragOffsetChanged,
    required this.onToggle,
  });

  @override
  State<WeeklyChatPanel> createState() => _WeeklyChatPanelState();
}

class _WeeklyChatPanelState extends State<WeeklyChatPanel>
    with SingleTickerProviderStateMixin {
  final TextEditingController messageController = TextEditingController();
  final FocusNode messageFocusNode = FocusNode();
  late final AnimationController dragAnimationController;
  bool sending = false;
  Stream<QuerySnapshot<Map<String, dynamic>>>? messagesStream;
  Stream<DocumentSnapshot<Map<String, dynamic>>>? readStateStream;
  DateTime? optimisticReadAt;
  String? lastReadWriteMarker;
  double dragOffset = 0;
  double dragAnimationStartOffset = 0;
  double dragAnimationEndOffset = 0;
  double lastExpandedPanelHeight = 0;

  @override
  void initState() {
    super.initState();
    dragAnimationController = AnimationController(
      vsync: this,
      duration: kWeeklyChatPanelAnimationDuration,
    )..addListener(_handleDragAnimationTick);
    configureMessagesStream();
    configureReadStateStream();
  }

  @override
  void didUpdateWidget(covariant WeeklyChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.groupId != widget.groupId ||
        oldWidget.weekKey != widget.weekKey) {
      configureMessagesStream();
      configureReadStateStream();
      optimisticReadAt = null;
      lastReadWriteMarker = null;
    }

    if (oldWidget.expanded != widget.expanded) {
      dragAnimationController.stop();
      dragOffset = 0;
    }
  }

  void configureMessagesStream() {
    if (widget.weekKey.isEmpty) {
      messagesStream = null;
      return;
    }

    messagesStream = FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.groupId)
        .collection('weeks')
        .doc(widget.weekKey)
        .collection('chatMessages')
        .orderBy('createdAt', descending: false)
        .snapshots();
  }

  void configureReadStateStream() {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      readStateStream = null;
      return;
    }

    readStateStream = FirebaseFirestore.instance
        .collection('users')
        .doc(currentUser.uid)
        .collection('groups')
        .doc(widget.groupId)
        .snapshots();
  }

  @override
  void dispose() {
    dragAnimationController.dispose();
    messageFocusNode.dispose();
    messageController.dispose();
    super.dispose();
  }

  bool get canWrite {
    return widget.weekKey.isNotEmpty &&
        esDomingo() &&
        widget.weekKey == obtenerWeekKeyActual();
  }

  String get weekLabel {
    if (widget.weekKey == obtenerWeekKeyActual()) {
      return 'ESTA SEMANA';
    }

    final parts = widget.weekKey.split('-W');
    if (parts.length == 2) {
      final weekNumber = int.tryParse(parts[1]) ?? 0;
      if (weekNumber > 0) return 'SEMANA $weekNumber / ${parts[0]}';
    }

    return widget.weekKey.toUpperCase();
  }

  Future<void> _send() async {
    if (sending || !canWrite) return;

    final text = messageController.text.trim();
    if (text.isEmpty) return;

    setState(() => sending = true);

    try {
      await enviarMensajeChatSemana(
        groupId: widget.groupId,
        weekKey: widget.weekKey,
        text: text,
      );

      messageController.clear();
    } catch (error) {
      if (!mounted) return;
      showSundaySnack(context, 'Error: $error');
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<void> _sendGif(SundayChatGif gif) async {
    if (sending || !canWrite) return;

    final caption = messageController.text.trim();

    setState(() => sending = true);

    try {
      await enviarMensajeChatSemana(
        groupId: widget.groupId,
        weekKey: widget.weekKey,
        text: caption,
        gifUrl: gif.url,
        gifLabel: gif.label,
      );

      messageController.clear();
    } catch (error) {
      if (!mounted) return;
      showSundaySnack(context, 'Error: $error');
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<void> _openGifPicker() async {
    if (sending || !canWrite) return;

    FocusScope.of(context).unfocus();

    final gif = await showModalBottomSheet<SundayChatGif>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const SundayGifPickerSheet(),
    );

    if (!mounted || gif == null) return;

    await _sendGif(gif);
  }

  DateTime? _messageCreatedAt(Map<String, dynamic> message) {
    final createdAt = message['createdAt'];
    if (createdAt is Timestamp) return createdAt.toDate();
    if (createdAt is DateTime) return createdAt;
    return null;
  }

  DateTime? _storedReadAt(Map<String, dynamic>? userGroupData) {
    final chatReads = userGroupData?['chatReads'];
    if (chatReads is! Map) return null;

    final weekReadState = chatReads[widget.weekKey];
    if (weekReadState is! Map) return null;

    final lastReadAt = weekReadState['lastReadAt'];
    if (lastReadAt is Timestamp) return lastReadAt.toDate();
    if (lastReadAt is DateTime) return lastReadAt;
    return null;
  }

  DateTime? _mostRecentReadAt(DateTime? storedReadAt) {
    final optimistic = optimisticReadAt;
    if (storedReadAt == null) return optimistic;
    if (optimistic == null) return storedReadAt;
    return optimistic.isAfter(storedReadAt) ? optimistic : storedReadAt;
  }

  int _unreadMessageCount({
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> messages,
    required DateTime? lastReadAt,
    required String? currentUid,
  }) {
    if (currentUid == null || messages.isEmpty) return 0;

    var unread = 0;
    for (final doc in messages) {
      final message = doc.data();
      if ((message['uid'] ?? '').toString() == currentUid) continue;

      final createdAt = _messageCreatedAt(message);
      if (createdAt == null) continue;

      if (lastReadAt == null || createdAt.isAfter(lastReadAt)) {
        unread += 1;
      }
    }

    return unread;
  }

  void _scheduleMarkReadIfNeeded({
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> messages,
    required int unreadCount,
  }) {
    if (!widget.expanded || unreadCount == 0 || messages.isEmpty) return;

    final latestMessage = messages.last;
    final marker = '${widget.weekKey}:${latestMessage.id}';
    if (lastReadWriteMarker == marker) return;

    lastReadWriteMarker = marker;
    final readThroughAt =
        _messageCreatedAt(latestMessage.data()) ?? DateTime.now();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.expanded) return;

      setState(() => optimisticReadAt = readThroughAt);
      unawaited(_markRead(marker));
    });
  }

  Future<void> _markRead(String marker) async {
    try {
      await marcarChatSemanaLeido(
        groupId: widget.groupId,
        weekKey: widget.weekKey,
      );
    } catch (error) {
      logDebug('No se pudo marcar el chat como leído: $error');
      if (mounted && lastReadWriteMarker == marker) {
        lastReadWriteMarker = null;
      }
    }
  }

  void _togglePanel() {
    if (widget.expanded) {
      _collapsePanel();
      return;
    }
    widget.onToggle();
  }

  void _collapsePanel() {
    if (!widget.expanded) return;
    messageFocusNode.unfocus();
    dragAnimationController.stop();
    if (dragOffset > 0) {
      _setDragOffset(0);
    }
    widget.onToggle();
  }

  void _setDragOffset(double offset) {
    final nextOffset = offset.isFinite ? math.max(0.0, offset) : 0.0;
    setState(() => dragOffset = nextOffset);
    widget.onDragOffsetChanged?.call(nextOffset);
  }

  void _handleDragAnimationTick() {
    final easedValue = kWeeklyChatPanelAnimationCurve.transform(
      dragAnimationController.value,
    );
    final nextOffset = lerpDouble(
      dragAnimationStartOffset,
      dragAnimationEndOffset,
      easedValue,
    );
    if (nextOffset == null) return;
    _setDragOffset(nextOffset);
  }

  double _panelDismissDistance() {
    if (lastExpandedPanelHeight > 0) return lastExpandedPanelHeight;

    return resolverAlturaPanelChatSemanal(
      screenHeight: MediaQuery.sizeOf(context).height,
      keyboardOpen: MediaQuery.viewInsetsOf(context).bottom > 0,
      canWrite: canWrite,
    );
  }

  Future<void> _animateDragOffset(double targetOffset) async {
    dragAnimationController.stop();
    dragAnimationStartOffset = dragOffset;
    dragAnimationEndOffset = targetOffset;

    final dismissDistance = math.max(_panelDismissDistance(), 1.0);
    final remainingFraction =
        (dragAnimationEndOffset - dragAnimationStartOffset).abs() /
        dismissDistance;
    final durationMs = math.max(
      90,
      (kWeeklyChatPanelAnimationDuration.inMilliseconds * remainingFraction)
          .round(),
    );
    dragAnimationController.duration = Duration(milliseconds: durationMs);

    try {
      await dragAnimationController.forward(from: 0).orCancel;
    } on TickerCanceled {
      return;
    }

    if (!mounted) return;

    _setDragOffset(targetOffset);
  }

  void _handlePanelDragStart() {
    if (!widget.expanded) return;
    dragAnimationController.stop();
  }

  void _handlePanelDragUpdate(double distance) {
    if (!widget.expanded) return;
    final safeDistance = _panelDismissDistance();
    _setDragOffset(distance.clamp(0.0, safeDistance).toDouble());
  }

  void _handlePanelDragEnd(double distance, double velocity) {
    if (!widget.expanded) return;

    final shouldDismiss =
        distance > kWeeklyChatDragDismissDistance ||
        velocity > kWeeklyChatDragDismissVelocity;

    if (shouldDismiss) {
      _collapsePanel();
    } else {
      unawaited(_animateDragOffset(0));
    }
  }

  void _handlePanelDragCancel() {
    if (!widget.expanded) return;
    unawaited(_animateDragOffset(0));
  }

  @override
  Widget build(BuildContext context) {
    SundayClockScope.watch(context);
    if (widget.weekKey.isEmpty) return const SizedBox.shrink();

    final currentMessagesStream = messagesStream;
    if (currentMessagesStream == null) return const SizedBox.shrink();
    final currentReadStateStream = readStateStream;

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: currentMessagesStream,
      builder: (context, snapshot) {
        final messages = snapshot.data?.docs ?? [];
        final currentUid = FirebaseAuth.instance.currentUser?.uid;

        Widget buildPanel(DateTime? storedReadAt, bool readStateReady) {
          final unreadCount = readStateReady
              ? _unreadMessageCount(
                  messages: messages,
                  lastReadAt: _mostRecentReadAt(storedReadAt),
                  currentUid: currentUid,
                )
              : 0;

          _scheduleMarkReadIfNeeded(
            messages: messages,
            unreadCount: unreadCount,
          );

          Widget animatedPanelSize(Widget child) {
            if (widget.fillAvailableHeight) return child;

            return AnimatedSize(
              duration: kWeeklyChatPanelAnimationDuration,
              curve: kWeeklyChatPanelAnimationCurve,
              alignment: Alignment.bottomCenter,
              child: child,
            );
          }

          if (!widget.expanded) {
            return animatedPanelSize(
              WeeklyChatCollapsedBar(
                canWrite: canWrite,
                unreadCount: unreadCount,
                onToggle: _togglePanel,
              ),
            );
          }

          final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
          final panelHeight = resolverAlturaPanelChatSemanal(
            screenHeight: MediaQuery.sizeOf(context).height,
            keyboardOpen: keyboardOpen,
            canWrite: canWrite,
            maxExpandedHeight: widget.maxExpandedHeight,
          );

          final panel = Container(
            decoration: const BoxDecoration(
              color: ssBg,
              border: Border(top: BorderSide(color: ssSeparator, width: 1)),
            ),
            child: Column(
              children: [
                WeeklyChatDragHandle(
                  onDismiss: _collapsePanel,
                  onDragStart: _handlePanelDragStart,
                  onDragUpdate: _handlePanelDragUpdate,
                  onDragEnd: _handlePanelDragEnd,
                  onDragCancel: _handlePanelDragCancel,
                ),
                WeeklyChatHeader(weekLabel: weekLabel),
                Expanded(
                  child: snapshot.connectionState == ConnectionState.waiting
                      ? const Center(
                          child: CircularProgressIndicator(
                            color: ssOrange,
                            strokeWidth: 2,
                          ),
                        )
                      : messages.isEmpty
                      ? WeeklyChatEmptyState(canWrite: canWrite)
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                          itemCount: messages.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final doc = messages[index];
                            return WeeklyChatMessageBubble(
                              message: doc.data(),
                              fallbackSeed: doc.id,
                            );
                          },
                        ),
                ),
                WeeklyChatInputBar(
                  canWrite: canWrite,
                  sending: sending,
                  controller: messageController,
                  focusNode: messageFocusNode,
                  onSend: _send,
                  onGif: _openGifPicker,
                  onToggle: _togglePanel,
                ),
              ],
            ),
          );

          if (widget.fillAvailableHeight) {
            return LayoutBuilder(
              builder: (context, constraints) {
                final panelDistance =
                    constraints.hasBoundedHeight &&
                        constraints.maxHeight.isFinite
                    ? constraints.maxHeight
                    : panelHeight;
                lastExpandedPanelHeight = panelDistance;
                final visibleDragOffset = dragOffset
                    .clamp(0.0, panelDistance)
                    .toDouble();

                return ClipRect(
                  child: Transform.translate(
                    offset: Offset(0, visibleDragOffset),
                    child: panel,
                  ),
                );
              },
            );
          }

          lastExpandedPanelHeight = panelHeight;
          final visibleDragOffset = dragOffset
              .clamp(0.0, panelHeight)
              .toDouble();

          return animatedPanelSize(
            SizedBox(
              height: panelHeight,
              child: ClipRect(
                child: Transform.translate(
                  offset: Offset(0, visibleDragOffset),
                  child: panel,
                ),
              ),
            ),
          );
        }

        if (currentReadStateStream == null) {
          return buildPanel(null, true);
        }

        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: currentReadStateStream,
          builder: (context, readSnapshot) {
            final readStateReady =
                readSnapshot.connectionState != ConnectionState.waiting ||
                readSnapshot.hasData;

            return buildPanel(
              _storedReadAt(readSnapshot.data?.data()),
              readStateReady,
            );
          },
        );
      },
    );
  }
}

class WeeklyChatCollapsedBar extends StatelessWidget {
  final bool canWrite;
  final int unreadCount;
  final VoidCallback onToggle;

  const WeeklyChatCollapsedBar({
    super.key,
    required this.canWrite,
    required this.unreadCount,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: ssBg,
        border: Border(top: BorderSide(color: ssSeparator, width: 1)),
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: SafeArea(
        top: false,
        bottom: false,
        child: Row(
          children: [
            Expanded(
              child: canWrite
                  ? Row(
                      children: [
                        WeeklyChatToggleButton(
                          expanded: false,
                          unreadCount: unreadCount,
                          onTap: onToggle,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: WeeklyChatPromptPill(
                            canWrite: true,
                            onTap: onToggle,
                          ),
                        ),
                      ],
                    )
                  : WeeklyChatPromptPill(
                      canWrite: false,
                      unreadCount: unreadCount,
                      onTap: onToggle,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class WeeklyChatHeader extends StatelessWidget {
  final String weekLabel;

  const WeeklyChatHeader({super.key, required this.weekLabel});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Row(
        children: [
          const Icon(
            Icons.chat_bubble_outline_rounded,
            color: ssText3,
            size: 14,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'CHAT · $weekLabel',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: ssText3,
                fontSize: 11,
                letterSpacing: 0.7,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class WeeklyChatDragHandle extends StatefulWidget {
  final VoidCallback onDismiss;
  final VoidCallback? onDragStart;
  final ValueChanged<double>? onDragUpdate;
  final void Function(double distance, double velocity)? onDragEnd;
  final VoidCallback? onDragCancel;

  const WeeklyChatDragHandle({
    super.key,
    required this.onDismiss,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.onDragCancel,
  });

  @override
  State<WeeklyChatDragHandle> createState() => _WeeklyChatDragHandleState();
}

class _WeeklyChatDragHandleState extends State<WeeklyChatDragHandle> {
  double dragDistance = 0;

  void _resetDrag() {
    dragDistance = 0;
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Minimizar chat',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onDismiss,
        onVerticalDragStart: (_) {
          _resetDrag();
          widget.onDragStart?.call();
        },
        onVerticalDragUpdate: (details) {
          final delta = details.primaryDelta ?? 0;
          dragDistance = math.max(0, dragDistance + delta);
          widget.onDragUpdate?.call(dragDistance);
        },
        onVerticalDragEnd: (details) {
          final distance = dragDistance;
          final velocity = details.primaryVelocity ?? 0;
          final shouldDismiss =
              distance > kWeeklyChatDragDismissDistance ||
              velocity > kWeeklyChatDragDismissVelocity;
          _resetDrag();
          final onDragEnd = widget.onDragEnd;
          if (onDragEnd != null) {
            onDragEnd(distance, velocity);
          } else if (shouldDismiss) {
            widget.onDismiss();
          }
        },
        onVerticalDragCancel: () {
          _resetDrag();
          widget.onDragCancel?.call();
        },
        child: SizedBox(
          width: double.infinity,
          height: 22,
          child: Center(
            child: Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: ssText3.withValues(alpha: 0.28),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class WeeklyChatEmptyState extends StatelessWidget {
  final bool canWrite;

  const WeeklyChatEmptyState({super.key, required this.canWrite});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            constraints.hasBoundedHeight && constraints.maxHeight < 96;

        return Center(
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 28,
              vertical: compact ? 4 : 0,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!compact) ...[
                  Container(
                    width: 42,
                    height: 42,
                    decoration: const BoxDecoration(
                      color: ssOrangeLight,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      canWrite
                          ? Icons.chat_bubble_outline_rounded
                          : Icons.lock_outline_rounded,
                      color: ssOrange,
                      size: 20,
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                Text(
                  canWrite
                      ? 'Todavía no hay mensajes esta semana.'
                      : 'No hubo mensajes esta semana.',
                  maxLines: compact ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: ssText3,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class WeeklyChatMessageBubble extends StatelessWidget {
  final Map<String, dynamic> message;
  final String fallbackSeed;

  const WeeklyChatMessageBubble({
    super.key,
    required this.message,
    required this.fallbackSeed,
  });

  @override
  Widget build(BuildContext context) {
    final uid = (message['uid'] ?? fallbackSeed).toString();
    final name = formatUserDisplayName(message['authorName'] ?? 'Usuario');
    final photoUrl = message['authorPhotoUrl'] as String?;
    final text = (message['text'] ?? '').toString();
    final gifUrl = (message['gifUrl'] ?? '').toString().trim();
    final gifLabel = (message['gifLabel'] ?? 'GIF').toString();
    final createdAt = message['createdAt'];
    final hasText = text.trim().isNotEmpty;
    final hasGif = gifUrl.isNotEmpty;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MiniProfileAvatar(
              name: name,
              photoUrl: photoUrl,
              size: 28,
              borderColor: ssBg,
            ),
            const SizedBox(height: 3),
            Text(
              formatChatMessageTime(createdAt),
              style: const TextStyle(
                color: ssText3,
                fontSize: 8,
                fontWeight: FontWeight.w700,
                height: 1,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                firstName(name),
                style: TextStyle(
                  color: memberAvatarColor(uid),
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  height: 1.1,
                ),
              ),
              const SizedBox(height: 3),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: ssSeparator, width: 1),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.035),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (hasText)
                      Text(
                        text,
                        style: const TextStyle(
                          color: ssTitle,
                          fontSize: 13,
                          height: 1.25,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    if (hasText && hasGif) const SizedBox(height: 8),
                    if (hasGif)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.network(
                          gifUrl,
                          width: 190,
                          height: 132,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          semanticLabel: gifLabel,
                          loadingBuilder: (context, child, loadingProgress) {
                            if (loadingProgress == null) return child;
                            return const SizedBox(
                              width: 190,
                              height: 132,
                              child: Center(
                                child: CircularProgressIndicator(
                                  color: ssOrange,
                                  strokeWidth: 2,
                                ),
                              ),
                            );
                          },
                          errorBuilder: (_, _, _) => Container(
                            width: 190,
                            height: 96,
                            alignment: Alignment.center,
                            color: ssOrangeLight,
                            child: const Text(
                              'GIF',
                              style: TextStyle(
                                color: ssOrangeDark,
                                fontSize: 12,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (!hasText && !hasGif)
                      const Text(
                        'Mensaje',
                        style: TextStyle(
                          color: ssText3,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class WeeklyChatInputBar extends StatelessWidget {
  final bool canWrite;
  final bool sending;
  final TextEditingController controller;
  final FocusNode? focusNode;
  final VoidCallback onSend;
  final VoidCallback onGif;
  final VoidCallback onToggle;

  const WeeklyChatInputBar({
    super.key,
    required this.canWrite,
    required this.sending,
    required this.controller,
    this.focusNode,
    required this.onSend,
    required this.onGif,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: ssBg,
        border: Border(top: BorderSide(color: ssSeparator, width: 1)),
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Row(
        children: [
          if (canWrite) ...[
            WeeklyChatToggleButton(
              expanded: true,
              unreadCount: 0,
              onTap: onToggle,
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: canWrite
                ? Container(
                    height: 40,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: ssBorder, width: 1.1),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Center(
                        child: TextField(
                          controller: controller,
                          focusNode: focusNode,
                          minLines: 1,
                          maxLines: 1,
                          maxLength: 500,
                          textAlignVertical: TextAlignVertical.center,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => onSend(),
                          cursorColor: ssOrange,
                          style: const TextStyle(
                            color: ssTitle,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                          decoration: const InputDecoration(
                            isCollapsed: true,
                            counterText: '',
                            hintText: 'Mensaje',
                            hintStyle: TextStyle(
                              color: ssText3,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      ),
                    ),
                  )
                : WeeklyChatPromptPill(canWrite: false, onTap: onToggle),
          ),
          if (canWrite) ...[
            const SizedBox(width: 8),
            Material(
              color: Colors.white,
              borderRadius: BorderRadius.circular(999),
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: sending ? null : onGif,
                child: Container(
                  height: 40,
                  padding: const EdgeInsets.symmetric(horizontal: 11),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: ssOrangeMid, width: 1.2),
                  ),
                  child: const Text(
                    'GIF',
                    style: TextStyle(
                      color: ssOrangeDark,
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Material(
              color: sending ? ssOrangeMid : ssOrangeMid,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: sending ? null : onSend,
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: sending
                      ? const Center(
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          ),
                        )
                      : const Icon(
                          Icons.send_rounded,
                          color: Colors.white,
                          size: 18,
                        ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class WeeklyChatPromptPill extends StatelessWidget {
  final bool canWrite;
  final int unreadCount;
  final VoidCallback onTap;

  const WeeklyChatPromptPill({
    super.key,
    required this.canWrite,
    this.unreadCount = 0,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = canWrite ? ssBorder : ssOrangeLight;
    final icon = canWrite
        ? Icons.chat_bubble_outline_rounded
        : Icons.lock_outline_rounded;
    final label = canWrite ? 'Mensaje' : 'Chat de domingo finalizado';

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(999),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(999),
            child: Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: borderColor, width: 1.1),
              ),
              child: Row(
                children: [
                  Icon(icon, color: ssText3, size: 15),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: ssText3,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (!canWrite && unreadCount > 0)
          Positioned(
            right: -1,
            top: -7,
            child: Container(
              constraints: const BoxConstraints(minWidth: 17, minHeight: 17),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: ssOrange,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: ssBg, width: 2),
              ),
              child: Text(
                unreadCount > 9 ? '9+' : '$unreadCount',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                  height: 1,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class WeeklyChatToggleButton extends StatelessWidget {
  final bool expanded;
  final int unreadCount;
  final VoidCallback onTap;

  const WeeklyChatToggleButton({
    super.key,
    required this.expanded,
    required this.unreadCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Material(
          color: Colors.white,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 40,
              height: 40,
              child: Icon(
                expanded
                    ? Icons.keyboard_arrow_down_rounded
                    : Icons.keyboard_arrow_up_rounded,
                color: ssOrange,
                size: 22,
              ),
            ),
          ),
        ),
        if (!expanded && unreadCount > 0)
          Positioned(
            right: -1,
            top: -7,
            child: Container(
              constraints: const BoxConstraints(minWidth: 17, minHeight: 17),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: ssOrange,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: ssBg, width: 2),
              ),
              child: Text(
                unreadCount > 9 ? '9+' : '$unreadCount',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                  height: 1,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class SundayChatGif {
  final String label;
  final String url;
  final List<String> keywords;

  const SundayChatGif({
    required this.label,
    required this.url,
    required this.keywords,
  });
}

class SundayGifSearchResult {
  final List<SundayChatGif> gifs;
  final String next;
  final bool fromTenor;
  final String? errorMessage;

  const SundayGifSearchResult({
    required this.gifs,
    required this.next,
    required this.fromTenor,
    this.errorMessage,
  });
}

class SundayGifRepository {
  static const int pageSize = 24;

  Future<SundayGifSearchResult> search({
    required String query,
    String? pos,
  }) async {
    final cleanQuery = query.trim();
    final cleanPos = pos?.trim() ?? '';

    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'buscarGifsTenor',
      );
      final response = await callable.call({
        'query': cleanQuery,
        'pos': cleanPos,
        'limit': pageSize,
      });
      final data = response.data;

      if (data is! Map) {
        throw const FormatException('Respuesta de GIFs no válida');
      }

      final rawGifs = data['gifs'];
      final gifs = rawGifs is List
          ? rawGifs
                .map(_gifFromCallableMap)
                .whereType<SundayChatGif>()
                .toList(growable: false)
          : <SundayChatGif>[];

      return SundayGifSearchResult(
        gifs: gifs,
        next: (data['next'] ?? '').toString(),
        fromTenor: true,
      );
    } catch (error) {
      logDebug('No se pudo cargar GIFs de Tenor: $error');

      return SundayGifSearchResult(
        gifs: const [],
        next: '',
        fromTenor: false,
        errorMessage: _searchErrorMessage(
          error,
          paginating: cleanPos.isNotEmpty,
        ),
      );
    }
  }

  static SundayChatGif? _gifFromCallableMap(dynamic value) {
    if (value is! Map) return null;

    final url = (value['url'] ?? '').toString().trim();
    if (!_isTenorMediaUrl(url)) return null;

    final label = (value['label'] ?? 'GIF').toString().trim();
    final rawKeywords = value['keywords'];
    final keywords = rawKeywords is List
        ? rawKeywords
              .map((keyword) => keyword.toString().trim().toLowerCase())
              .where((keyword) => keyword.isNotEmpty)
              .toList(growable: false)
        : <String>[];

    return SundayChatGif(
      label: label.isEmpty ? 'GIF' : label,
      url: url,
      keywords: keywords,
    );
  }

  static bool _isTenorMediaUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host == 'media.tenor.com' &&
        uri.path.isNotEmpty;
  }

  static String _searchErrorMessage(Object error, {required bool paginating}) {
    if (paginating) return 'No se pudieron cargar más GIFs';

    if (error is FirebaseFunctionsException) {
      if (error.code == 'failed-precondition') {
        return 'La biblioteca de GIFs no está configurada todavía';
      }

      return error.message ?? 'No se pudo cargar la biblioteca de GIFs';
    }

    return 'No se pudo cargar la biblioteca de GIFs';
  }
}

class SundayGifPickerSheet extends StatefulWidget {
  const SundayGifPickerSheet({super.key});

  @override
  State<SundayGifPickerSheet> createState() => _SundayGifPickerSheetState();
}

class _SundayGifPickerSheetState extends State<SundayGifPickerSheet> {
  final TextEditingController searchController = TextEditingController();
  final ScrollController scrollController = ScrollController();
  final SundayGifRepository gifRepository = SundayGifRepository();
  Timer? searchDebounce;
  List<SundayChatGif> gifs = const [];
  String nextPagePosition = '';
  String query = '';
  String? errorMessage;
  bool loading = true;
  bool loadingMore = false;
  bool showingTenorResults = false;
  int requestGeneration = 0;

  @override
  void initState() {
    super.initState();
    scrollController.addListener(_handleScroll);
    unawaited(_loadGifs(reset: true));
  }

  @override
  void dispose() {
    searchDebounce?.cancel();
    searchController.dispose();
    scrollController.dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (!scrollController.hasClients ||
        loading ||
        loadingMore ||
        nextPagePosition.isEmpty) {
      return;
    }

    final position = scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 420) {
      unawaited(_loadGifs(reset: false));
    }
  }

  void _handleSearchChanged(String value) {
    query = value;
    searchDebounce?.cancel();
    searchDebounce = Timer(
      const Duration(milliseconds: 320),
      () => _loadGifs(reset: true),
    );
  }

  Future<void> _loadGifs({required bool reset}) async {
    if (!reset && (loading || loadingMore || nextPagePosition.isEmpty)) {
      return;
    }

    final generation = reset ? ++requestGeneration : requestGeneration;
    final searchQuery = query;
    final pagePosition = reset ? null : nextPagePosition;
    if (reset && scrollController.hasClients) {
      scrollController.jumpTo(0);
    }

    setState(() {
      if (reset) {
        loading = true;
        loadingMore = false;
        nextPagePosition = '';
        gifs = const [];
        errorMessage = null;
      } else {
        loadingMore = true;
      }
    });

    final result = await gifRepository.search(
      query: searchQuery,
      pos: pagePosition,
    );

    if (!mounted || generation != requestGeneration) return;

    setState(() {
      if (reset) {
        gifs = result.gifs;
        showingTenorResults = result.fromTenor;
        errorMessage = result.errorMessage;
      } else {
        final seenUrls = gifs.map((gif) => gif.url).toSet();
        gifs = [...gifs, ...result.gifs.where((gif) => seenUrls.add(gif.url))];
        showingTenorResults = showingTenorResults || result.fromTenor;
        errorMessage = result.errorMessage;
      }

      nextPagePosition = result.next;
      loading = false;
      loadingMore = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final currentErrorMessage = errorMessage;

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.78,
          ),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              SizedBox(
                width: double.infinity,
                height: 44,
                child: Stack(
                  alignment: Alignment.topCenter,
                  children: [
                    Positioned(
                      top: 10,
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: ssBorder,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 2,
                      right: 8,
                      child: IconButton(
                        tooltip: 'Cerrar',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close_rounded, color: ssText3),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                child: Container(
                  height: 42,
                  decoration: BoxDecoration(
                    color: ssBg,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: ssBorder, width: 1),
                  ),
                  child: TextField(
                    controller: searchController,
                    cursorColor: ssOrange,
                    textInputAction: TextInputAction.search,
                    onChanged: _handleSearchChanged,
                    style: const TextStyle(
                      color: ssTitle,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      prefixIcon: const Icon(
                        Icons.search_rounded,
                        color: ssText3,
                        size: 20,
                      ),
                      hintText: showingTenorResults
                          ? 'Buscar en Tenor'
                          : 'Buscar GIFs',
                      hintStyle: const TextStyle(
                        color: ssText3,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                      contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: loading && gifs.isEmpty
                    ? const Center(
                        child: CircularProgressIndicator(
                          color: ssOrange,
                          strokeWidth: 2,
                        ),
                      )
                    : currentErrorMessage != null && gifs.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 26),
                          child: Text(
                            currentErrorMessage,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: ssText3,
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              height: 1.25,
                            ),
                          ),
                        ),
                      )
                    : gifs.isEmpty
                    ? const Center(
                        child: Text(
                          'Sin GIFs para esa búsqueda',
                          style: TextStyle(
                            color: ssText3,
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      )
                    : GridView.builder(
                        controller: scrollController,
                        padding: const EdgeInsets.fromLTRB(18, 2, 18, 22),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              mainAxisSpacing: 12,
                              crossAxisSpacing: 12,
                              childAspectRatio: 1.06,
                            ),
                        itemCount: gifs.length + (loadingMore ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index >= gifs.length) {
                            return const Center(
                              child: CircularProgressIndicator(
                                color: ssOrange,
                                strokeWidth: 2,
                              ),
                            );
                          }

                          final gif = gifs[index];
                          return Material(
                            color: Colors.white,
                            elevation: 5,
                            shadowColor: Colors.black.withValues(alpha: 0.22),
                            surfaceTintColor: Colors.transparent,
                            borderRadius: BorderRadius.circular(12),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onTap: () => Navigator.pop(context, gif),
                              child: Image.network(
                                gif.url,
                                width: double.infinity,
                                height: double.infinity,
                                fit: BoxFit.cover,
                                gaplessPlayback: true,
                                semanticLabel: gif.label,
                                loadingBuilder:
                                    (context, child, loadingProgress) {
                                      if (loadingProgress == null) {
                                        return child;
                                      }

                                      return const Center(
                                        child: CircularProgressIndicator(
                                          color: ssOrange,
                                          strokeWidth: 2,
                                        ),
                                      );
                                    },
                                errorBuilder: (_, _, _) => const Center(
                                  child: Text(
                                    'GIF',
                                    style: TextStyle(
                                      color: ssOrangeDark,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
              if (showingTenorResults)
                const Padding(
                  padding: EdgeInsets.fromLTRB(18, 0, 18, 12),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      'Powered by Tenor',
                      style: TextStyle(
                        color: ssText3,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String formatChatMessageTime(dynamic value) {
  DateTime? date;

  if (value is Timestamp) {
    date = value.toDate();
  } else if (value is DateTime) {
    date = value;
  }

  if (date == null) return '';

  return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
}

class GroupWeekSummaryCard extends StatelessWidget {
  final String weekKey;
  final int postedCount;
  final int memberCount;

  const GroupWeekSummaryCard({
    super.key,
    required this.weekKey,
    required this.postedCount,
    required this.memberCount,
  });

  @override
  Widget build(BuildContext context) {
    final total = memberCount <= 0 ? postedCount : memberCount;
    final progress = total == 0 ? 0.0 : (postedCount / total).clamp(0.0, 1.0);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: ssBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      obtenerEtiquetaSemana(weekKey),
                      style: const TextStyle(
                        color: ssText,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      esDomingo()
                          ? 'Hoy se actualiza el grupo'
                          : 'Selfies publicados esta semana',
                      style: const TextStyle(
                        color: ssText2,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: ssOrangeLight,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: ssOrangeMid),
                ),
                child: Text(
                  '$postedCount/$total',
                  style: const TextStyle(
                    color: ssOrangeDark,
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              minHeight: 8,
              value: progress,
              backgroundColor: ssSeparator,
              valueColor: const AlwaysStoppedAnimation<Color>(ssOrange),
            ),
          ),
        ],
      ),
    );
  }
}

class EmptyWeekCard extends StatelessWidget {
  final String weekKey;

  const EmptyWeekCard({super.key, required this.weekKey});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: ssOrangeLight,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: ssOrangeMid, width: 1.5),
      ),
      child: Column(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: const BoxDecoration(
              color: ssOrange,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.camera_alt_rounded, color: Colors.white),
          ),
          const SizedBox(height: 14),
          const Text(
            'Todavía no hay selfies',
            style: TextStyle(
              color: ssOrangeDark,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            obtenerEtiquetaSemana(weekKey),
            style: const TextStyle(
              color: ssText2,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class MissingSelfieTile extends StatefulWidget {
  final String groupId;
  final String groupName;
  final String? groupPhotoUrl;
  final String weekKey;
  final String targetUid;
  final String name;
  final String? photoUrl;
  final dynamic joinedAt;

  const MissingSelfieTile({
    super.key,
    required this.groupId,
    required this.groupName,
    required this.groupPhotoUrl,
    required this.weekKey,
    required this.targetUid,
    required this.name,
    required this.photoUrl,
    required this.joinedAt,
  });

  @override
  State<MissingSelfieTile> createState() => _MissingSelfieTileState();
}

class _MissingSelfieTileState extends State<MissingSelfieTile> {
  bool openingCameraOrUploading = false;

  Future<void> _openCameraAndUpload() async {
    if (openingCameraOrUploading) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null || user.uid != widget.targetUid) return;

    final window = obtenerSundayWindowState();
    final isCurrentWeek = widget.weekKey == obtenerWeekKeyActual();
    final isRegularSundayUpload = isCurrentWeek && window.canUpload;
    final isLateMondayUpload = miembroPuedeSubirSelfieLunesConRetraso(
      widget.weekKey,
      widget.joinedAt,
    );

    if (!isRegularSundayUpload && !isLateMondayUpload) {
      showSundaySnack(context, 'La ventana de subida está cerrada');
      return;
    }

    setState(() => openingCameraOrUploading = true);

    try {
      if (isLateMondayUpload) {
        final unlocked = await prepararSelfieConRetrasoConAnuncio(context);
        if (!mounted || !unlocked) return;
      }

      final foto = await Navigator.push<XFile>(
        context,
        MaterialPageRoute(
          builder: (_) => CameraCaptureScreen(groupName: widget.groupName),
        ),
      );

      if (!mounted || foto == null) return;
      final validPhoto = await validarFotoSelfieParaSubida(context, foto);
      if (!mounted || !validPhoto) return;

      await publicarSelfieReal(
        groupId: widget.groupId,
        user: user,
        foto: foto,
        weekKey: widget.weekKey,
        rewardedAdWatched: isLateMondayUpload,
      );

      if (!mounted) return;
      showSundaySnack(
        context,
        'Selfie publicado en ${formatGroupDisplayName(widget.groupName)}',
      );
    } on SelfiePhotoValidationException catch (error) {
      if (!mounted) return;
      showSundaySnack(context, error.message);
    } catch (error) {
      if (!mounted) return;
      showSundaySnack(context, 'Error: $error');
    } finally {
      if (mounted) {
        setState(() => openingCameraOrUploading = false);
      }
    }
  }

  void _openMemberSelfies() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GroupMemberSelfiesScreen(
          groupId: widget.groupId,
          groupName: widget.groupName,
          groupPhotoUrl: widget.groupPhotoUrl,
          memberUid: widget.targetUid,
          memberName: widget.name,
          memberPhotoUrl: widget.photoUrl,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    SundayClockScope.watch(context);
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    final isMe = currentUid == widget.targetUid;
    final canUploadSelfie =
        isMe &&
        widget.weekKey == obtenerWeekKeyActual() &&
        obtenerSundayWindowState().canUpload;
    final canUploadLateSelfie =
        isMe &&
        miembroPuedeSubirSelfieLunesConRetraso(widget.weekKey, widget.joinedAt);
    final canTapSelfie = canUploadSelfie || canUploadLateSelfie;
    final displayName = formatUserDisplayName(widget.name);
    final statusLabel = missingSundaySelfieStatusLabel(widget.weekKey);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _openMemberSelfies,
          child: SizedBox(
            height: 32,
            child: Row(
              children: [
                MiniProfileAvatar(
                  name: displayName,
                  photoUrl: widget.photoUrl,
                  size: 24,
                  borderColor: ssBg,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: ssTitle,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w900,
                      height: 1,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: CustomPaint(
            foregroundPainter: const SundayDashedBorderPainter(
              color: ssOrangeMid,
              radius: 18,
              strokeWidth: 0.9,
              dashLength: 4,
              gapLength: 4,
            ),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(18),
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: canTapSelfie && !openingCameraOrUploading
                    ? _openCameraAndUpload
                    : null,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Spacer(),
                      if (openingCameraOrUploading)
                        const SizedBox(
                          width: 54,
                          height: 54,
                          child: Padding(
                            padding: EdgeInsets.all(12),
                            child: CircularProgressIndicator(
                              color: ssOrange,
                              strokeWidth: 2.5,
                            ),
                          ),
                        )
                      else
                        MiniProfileAvatar(
                          name: displayName,
                          photoUrl: widget.photoUrl,
                          size: 54,
                          borderColor: ssBg,
                        ),
                      const SizedBox(height: 8),
                      Text(
                        displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: ssText3,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        statusLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: ssText3,
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (canTapSelfie) ...[
                        const SizedBox(height: 8),
                        Icon(
                          canUploadLateSelfie
                              ? Icons.lock_clock_rounded
                              : Icons.photo_camera_rounded,
                          color: openingCameraOrUploading
                              ? ssText3
                              : ssOrangeDark,
                          size: 18,
                        ),
                      ],
                      const Spacer(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        const MissingSelfieReactionPlaceholder(),
      ],
    );
  }
}

class MissingSelfieReactionPlaceholder extends StatelessWidget {
  const MissingSelfieReactionPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 31,
      child: CustomPaint(
        foregroundPainter: SundayDashedBorderPainter(
          color: ssOrangeMid,
          radius: 999,
          strokeWidth: 0.9,
          dashLength: 4,
          gapLength: 4,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.all(Radius.circular(999)),
          ),
          child: SizedBox.expand(),
        ),
      ),
    );
  }
}

class MissingSelfieReminderButton extends StatelessWidget {
  final String groupId;
  final String weekKey;
  final String targetUid;
  final bool sending;
  final bool preparingExtraReminder;
  final bool extraReminderUnlocked;
  final VoidCallback onTap;
  final VoidCallback onPrepareExtraReminder;

  const MissingSelfieReminderButton({
    super.key,
    required this.groupId,
    required this.weekKey,
    required this.targetUid,
    required this.sending,
    required this.preparingExtraReminder,
    required this.extraReminderUnlocked,
    required this.onTap,
    required this.onPrepareExtraReminder,
  });

  @override
  Widget build(BuildContext context) {
    SundayClockScope.watch(context);
    final currentUid = FirebaseAuth.instance.currentUser?.uid;

    if (currentUid == null || !esDomingo()) return const SizedBox.shrink();

    final targetRemindersRef = FirebaseFirestore.instance
        .collection('groups')
        .doc(groupId)
        .collection('weeks')
        .doc(weekKey)
        .collection('reminders')
        .where('targetUid', isEqualTo: targetUid)
        .limit(1);

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: targetRemindersRef.snapshots(),
      builder: (context, snapshot) {
        final sent = snapshot.data?.docs.isNotEmpty ?? false;
        final needsAd = sent && !extraReminderUnlocked;
        final busy = sending || preparingExtraReminder;

        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: busy
                ? null
                : needsAd
                ? onPrepareExtraReminder
                : onTap,
            child: Container(
              height: 31,
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: busy ? ssBorder : ssOrangeMid,
                  width: 1.2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.045),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      needsAd
                          ? Icons.check_rounded
                          : Icons.notifications_none_rounded,
                      color: busy ? ssText3 : ssOrangeDark,
                      size: 13,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      sending
                          ? 'Enviando...'
                          : preparingExtraReminder
                          ? 'Anuncio...'
                          : needsAd
                          ? 'Zumbido enviado'
                          : 'Enviar zumbido',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: busy ? ssText3 : ssOrangeDark,
                        fontSize: 9.4,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class SelfieTile extends StatelessWidget {
  final String groupId;
  final String groupName;
  final String? groupPhotoUrl;
  final String weekKey;
  final String postUid;
  final Map<String, dynamic> post;
  final VoidCallback onTap;

  const SelfieTile({
    super.key,
    required this.groupId,
    required this.groupName,
    required this.groupPhotoUrl,
    required this.weekKey,
    required this.postUid,
    required this.post,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final authorName = formatUserDisplayName(post['authorName'] ?? 'Usuario');
    final postAuthorPhotoUrl = post['authorPhotoUrl'] as String?;
    final imageUrl = (post['thumbUrl'] ?? post['imageUrl'] ?? '').toString();

    final memberRef = FirebaseFirestore.instance
        .collection('groups')
        .doc(groupId)
        .collection('members')
        .doc(postUid);

    final reactionsRef = FirebaseFirestore.instance
        .collection('groups')
        .doc(groupId)
        .collection('weeks')
        .doc(weekKey)
        .collection('posts')
        .doc(postUid)
        .collection('reactions')
        .orderBy('updatedAt', descending: true);

    void openAuthorSelfies({
      required String memberName,
      required String? memberPhotoUrl,
    }) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => GroupMemberSelfiesScreen(
            groupId: groupId,
            groupName: groupName,
            groupPhotoUrl: groupPhotoUrl,
            memberUid: postUid,
            memberName: memberName,
            memberPhotoUrl: memberPhotoUrl,
          ),
        ),
      );
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: memberRef.snapshots(),
              builder: (context, memberSnapshot) {
                final memberData = memberSnapshot.data?.data();
                final memberPhotoUrl =
                    memberData?['effectivePhotoUrl'] as String?;
                final memberName = formatUserDisplayName(
                  memberData?['effectiveName'] ?? authorName,
                );
                final resolvedPhotoUrl =
                    postAuthorPhotoUrl != null &&
                        postAuthorPhotoUrl.trim().isNotEmpty
                    ? postAuthorPhotoUrl
                    : memberPhotoUrl;

                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => openAuthorSelfies(
                    memberName: memberName,
                    memberPhotoUrl: resolvedPhotoUrl,
                  ),
                  child: SizedBox(
                    height: 32,
                    child: Row(
                      children: [
                        MiniProfileAvatar(
                          name: memberName,
                          photoUrl: resolvedPhotoUrl,
                          size: 24,
                          borderColor: ssBg,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            memberName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: ssTitle,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w900,
                              height: 1,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Container(
                  width: double.infinity,
                  color: ssOrangeLight,
                  child: imageUrl.isNotEmpty
                      ? CachedRemoteImage(
                          imageUrl: imageUrl,
                          cacheVariant: 'thumbnail',
                          fit: BoxFit.cover,
                          alignment: Alignment.center,
                          filterQuality: FilterQuality.high,
                          loadingWidget: const _ImageLoadingFill(),
                          errorWidget: Center(
                            child: Text(
                              initialsFromName(authorName),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 38,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        )
                      : Center(
                          child: Text(
                            initialsFromName(authorName),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 38,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            GroupAggregatedReactionsStrip(reactionsRef: reactionsRef),
          ],
        ),
      ),
    );
  }
}

class GroupAggregatedReactionsStrip extends StatelessWidget {
  final Query<Map<String, dynamic>> reactionsRef;
  final bool compact;
  final bool overlay;
  final bool plain;
  final bool hideWhenEmpty;

  const GroupAggregatedReactionsStrip({
    super.key,
    required this.reactionsRef,
    this.compact = false,
    this.overlay = false,
    this.plain = false,
    this.hideWhenEmpty = false,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: reactionsRef.snapshots(),
      builder: (context, snapshot) {
        final reactions = snapshot.data?.docs ?? [];
        final counts = <String, int>{};

        for (final reaction in reactions) {
          final emoji = normalizarEmojiReaccion(
            (reaction.data()['emoji'] ?? '').toString(),
          );
          if (emoji.isEmpty) continue;
          counts[emoji] = (counts[emoji] ?? 0) + 1;
        }

        if (counts.isEmpty && hideWhenEmpty) {
          return const SizedBox.shrink();
        }

        final overlayTextShadow = [
          Shadow(
            color: Colors.black.withValues(alpha: 0.42),
            blurRadius: 5,
            offset: const Offset(0, 1),
          ),
        ];

        return Container(
          height: compact ? 28 : 31,
          decoration: overlay || plain
              ? null
              : BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(999),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.045),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(
              horizontal: overlay || plain ? 0 : (compact ? 8 : 10),
              vertical: compact ? 5 : 6,
            ),
            itemCount: counts.length,
            separatorBuilder: (_, _) => SizedBox(width: compact ? 6 : 7),
            itemBuilder: (context, index) {
              final entry = counts.entries.elementAt(index);
              return InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () => showReactionUsersSheet(
                  context: context,
                  emoji: entry.key,
                  reactions: reactions,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      entry.key,
                      style: TextStyle(fontSize: compact ? 13 : 14, height: 1),
                    ),
                    if (entry.value > 1) ...[
                      const SizedBox(width: 2),
                      Text(
                        '${entry.value}',
                        style: TextStyle(
                          color: overlay ? Colors.white : ssTitle,
                          fontSize: compact ? 13 : 14,
                          fontWeight: FontWeight.w900,
                          height: 1,
                          shadows: overlay ? overlayTextShadow : null,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class SelfieViewerEntry {
  final String groupId;
  final String groupName;
  final String? groupPhotoUrl;
  final String weekKey;
  final String postUid;
  final Map<String, dynamic> post;

  const SelfieViewerEntry({
    required this.groupId,
    this.groupName = 'Grupo',
    this.groupPhotoUrl,
    required this.weekKey,
    required this.postUid,
    required this.post,
  });
}

enum _SelfieViewerAction {
  downloadSelfie,
  replaceProfilePhoto,
  report,
  deleteSelfie,
}

class SelfieFullScreen extends StatefulWidget {
  final String groupId;
  final String groupName;
  final String? groupPhotoUrl;
  final String weekKey;
  final String postUid;
  final Map<String, dynamic> post;
  final List<SelfieViewerEntry>? galleryEntries;
  final int initialIndex;

  const SelfieFullScreen({
    super.key,
    required this.groupId,
    this.groupName = 'Grupo',
    this.groupPhotoUrl,
    required this.weekKey,
    required this.postUid,
    required this.post,
    this.galleryEntries,
    this.initialIndex = 0,
  });

  @override
  State<SelfieFullScreen> createState() => _SelfieFullScreenState();
}

class _SelfieFullScreenState extends State<SelfieFullScreen> {
  bool sendingReaction = false;
  bool sendingReport = false;
  bool replacingProfilePhoto = false;
  bool downloadingSelfie = false;
  bool deletingSelfie = false;
  late int currentIndex;
  late PageController pageController;

  List<SelfieViewerEntry> get entries {
    final provided = widget.galleryEntries;
    if (provided != null && provided.isNotEmpty) return provided;
    return [
      SelfieViewerEntry(
        groupId: widget.groupId,
        groupName: widget.groupName,
        groupPhotoUrl: widget.groupPhotoUrl,
        weekKey: widget.weekKey,
        postUid: widget.postUid,
        post: widget.post,
      ),
    ];
  }

  @override
  void initState() {
    super.initState();
    final maxIndex = entries.length - 1;
    currentIndex = widget.initialIndex
        .clamp(0, maxIndex < 0 ? 0 : maxIndex)
        .toInt();
    pageController = PageController(initialPage: currentIndex);
  }

  @override
  void didUpdateWidget(covariant SelfieFullScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.galleryEntries != widget.galleryEntries) {
      final maxIndex = entries.length - 1;
      currentIndex = currentIndex.clamp(0, maxIndex < 0 ? 0 : maxIndex).toInt();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !pageController.hasClients) return;
        pageController.jumpToPage(currentIndex);
      });
    }
  }

  void _setCurrentIndex(int index) {
    final list = entries;
    final next = index.clamp(0, list.length - 1).toInt();
    if (next == currentIndex) return;
    setState(() {
      currentIndex = next;
      sendingReaction = false;
      sendingReport = false;
      downloadingSelfie = false;
      deletingSelfie = false;
    });
  }

  @override
  void dispose() {
    pageController.dispose();
    super.dispose();
  }

  void _openAuthorSelfies(
    SelfieViewerEntry entry, {
    required String authorName,
    required String? authorPhotoUrl,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GroupMemberSelfiesScreen(
          groupId: entry.groupId,
          groupName: entry.groupName,
          groupPhotoUrl: entry.groupPhotoUrl,
          memberUid: entry.postUid,
          memberName: authorName,
          memberPhotoUrl: authorPhotoUrl,
        ),
      ),
    );
  }

  Future<void> _sendReaction(SelfieViewerEntry entry, String emoji) async {
    if (sendingReaction) return;

    setState(() => sendingReaction = true);
    try {
      await reaccionarASelfie(
        groupId: entry.groupId,
        weekKey: entry.weekKey,
        postUid: entry.postUid,
        emoji: emoji,
      );
    } catch (error) {
      final isOwnReactionError = error.toString().contains(
        'No puedes reaccionar a tu propio selfie',
      );
      if (mounted && !isOwnReactionError) {
        showSundaySnack(context, 'Error al reaccionar: $error');
      }
    } finally {
      if (mounted) {
        setState(() => sendingReaction = false);
      }
    }
  }

  Future<void> _openReactionPicker({
    required String? currentReaction,
    required bool canReact,
    required String unavailableMessage,
    required ValueChanged<String> onReact,
  }) async {
    if (sendingReaction) return;

    if (!canReact) {
      final message = unavailableMessage.trim();
      if (message.isNotEmpty) showSundaySnack(context, message);
      return;
    }

    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) =>
          EmojiReactionPickerSheet(currentReaction: currentReaction),
    );

    if (selected == null || selected.isEmpty) return;
    onReact(selected);
  }

  Future<void> _handleImageReactionHold(
    SelfieViewerEntry entry, {
    required bool isOwnSelfie,
    required String? currentReaction,
  }) async {
    if (sendingReaction || isOwnSelfie) return;

    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      showSundaySnack(context, 'Inicia sesión para reaccionar');
      return;
    }

    final myPostRef = FirebaseFirestore.instance
        .collection('groups')
        .doc(entry.groupId)
        .collection('weeks')
        .doc(entry.weekKey)
        .collection('posts')
        .doc(currentUser.uid);

    final myPostSnapshot = await myPostRef.get();
    if (!mounted) return;

    final hasPublishedThisWeek = myPostSnapshot.exists;
    final isCurrentSundayWeek =
        esDomingo() && entry.weekKey == obtenerWeekKeyActual();
    if (!isCurrentSundayWeek && currentReaction != null) return;

    final missingCurrentSundaySelfie =
        !hasPublishedThisWeek &&
        esDomingo() &&
        entry.weekKey == obtenerWeekKeyActual();

    await _openReactionPicker(
      currentReaction: currentReaction,
      canReact: hasPublishedThisWeek,
      unavailableMessage: missingCurrentSundaySelfie
          ? 'Sube tu selfie semanal para poder reaccionar'
          : '',
      onReact: (emoji) => unawaited(_sendReaction(entry, emoji)),
    );
  }

  Future<void> _reportSelfie(SelfieViewerEntry entry) async {
    if (sendingReport) return;

    final reason = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Reportar esta selfie',
                  style: TextStyle(
                    color: ssText,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'El reporte será privado y se enviará para revisión.',
                  style: TextStyle(color: ssText2, fontSize: 13, height: 1.35),
                ),
                const SizedBox(height: 12),
                ...kSelfieReportReasons.entries.map((entry) {
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(
                      Icons.flag_outlined,
                      color: ssOrangeDark,
                    ),
                    title: Text(
                      entry.value,
                      style: const TextStyle(
                        color: ssText,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    onTap: () => Navigator.pop(sheetContext, entry.key),
                  );
                }),
              ],
            ),
          ),
        );
      },
    );

    if (reason == null || !mounted) return;

    setState(() => sendingReport = true);

    try {
      await reportarSelfie(
        groupId: entry.groupId,
        weekKey: entry.weekKey,
        postUid: entry.postUid,
        reason: reason,
      );

      if (!mounted) return;
      showSundaySnack(context, 'Reporte enviado para revisión');
    } catch (error) {
      if (!mounted) return;
      showSundaySnack(context, 'Error enviando el reporte: $error');
    } finally {
      if (mounted) setState(() => sendingReport = false);
    }
  }

  Future<void> _replaceProfilePhoto(SelfieViewerEntry entry) async {
    if (replacingProfilePhoto) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null || user.uid != entry.postUid) {
      showSundaySnack(context, 'Solo puedes usar tus propias selfies');
      return;
    }

    final imageUrl = (entry.post['imageUrl'] ?? entry.post['thumbUrl'] ?? '')
        .toString()
        .trim();
    if (imageUrl.isEmpty) {
      showSundaySnack(context, 'Esta selfie no tiene una imagen disponible');
      return;
    }

    setState(() => replacingProfilePhoto = true);

    try {
      final unlocked = await prepararCambioFotoPerfilConAnuncio(context);
      if (!mounted || !unlocked) return;

      await reemplazarFotoPerfilConSelfie(user: user, selfieUrl: imageUrl);

      if (!mounted) return;
      showSundaySnack(context, 'Foto de perfil actualizada');
    } catch (error) {
      if (!mounted) return;
      showSundaySnack(context, 'Error actualizando foto: $error');
    } finally {
      if (mounted) setState(() => replacingProfilePhoto = false);
    }
  }

  Future<void> _downloadSelfie(SelfieViewerEntry entry) async {
    if (downloadingSelfie) return;

    final imageUrl = (entry.post['imageUrl'] ?? entry.post['thumbUrl'] ?? '')
        .toString()
        .trim();
    if (imageUrl.isEmpty) {
      showSundaySnack(context, 'Esta selfie no tiene una imagen disponible');
      return;
    }

    final authorName = formatUserDisplayName(
      entry.post['authorName'] ?? 'Usuario',
    );

    setState(() => downloadingSelfie = true);
    showSundaySnack(context, 'Guardando selfie...');

    try {
      final file = await descargarSelfieIndividual(
        imageUrl: imageUrl,
        groupName: entry.groupName,
        weekKey: entry.weekKey,
        authorName: authorName,
      );

      if (!mounted) return;
      final savedCount = await guardarArchivosDescargadosEnTelefono(
        files: [file],
      );

      if (!mounted) return;
      showSundaySnack(
        context,
        savedCount == 0
            ? 'No se pudo guardar la selfie'
            : 'Selfie guardada en el teléfono',
      );
    } catch (error) {
      if (!mounted) return;
      final message = mensajeErrorGuardandoArchivos(error);
      showSundaySnack(
        context,
        error is UnsupportedError || message.contains('Fotos')
            ? message
            : 'No se pudo guardar la selfie en el teléfono',
      );
    } finally {
      if (mounted) setState(() => downloadingSelfie = false);
    }
  }

  Future<bool> _confirmDeleteSelfie() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          title: const Text('Borrar selfie'),
          content: const Text(
            'Esta selfie se eliminará definitivamente, también de la nube. Esta acción no se puede deshacer.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancelar'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text(
                'Sí, borrar',
                style: TextStyle(
                  color: Color(0xFFE74C3C),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        );
      },
    );

    return confirmed == true;
  }

  Future<void> _deleteSelfie(SelfieViewerEntry entry) async {
    if (deletingSelfie) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null || user.uid != entry.postUid) {
      showSundaySnack(context, 'Solo puedes borrar tus propias selfies');
      return;
    }

    final confirmed = await _confirmDeleteSelfie();
    if (!confirmed || !mounted) return;

    setState(() => deletingSelfie = true);

    var deleted = false;
    try {
      await borrarSelfie(
        groupId: entry.groupId,
        weekKey: entry.weekKey,
        postUid: entry.postUid,
      );
      deleted = true;
    } catch (error) {
      if (!mounted) return;
      showSundaySnack(context, 'Error borrando la selfie: $error');
    } finally {
      if (mounted && !deleted) setState(() => deletingSelfie = false);
    }

    if (!mounted || !deleted) return;
    showSundaySnack(context, 'Selfie borrada definitivamente');
    Navigator.pop(context);
  }

  void _handleSelfieAction(
    _SelfieViewerAction action,
    SelfieViewerEntry entry,
  ) {
    switch (action) {
      case _SelfieViewerAction.downloadSelfie:
        unawaited(_downloadSelfie(entry));
        break;
      case _SelfieViewerAction.replaceProfilePhoto:
        unawaited(_replaceProfilePhoto(entry));
        break;
      case _SelfieViewerAction.report:
        unawaited(_reportSelfie(entry));
        break;
      case _SelfieViewerAction.deleteSelfie:
        unawaited(_deleteSelfie(entry));
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = entries;
    final currentUser = FirebaseAuth.instance.currentUser;

    return Scaffold(
      backgroundColor: ssBg,
      body: PageView.builder(
        controller: pageController,
        scrollDirection: Axis.vertical,
        physics: const PageScrollPhysics(parent: BouncingScrollPhysics()),
        itemCount: list.length,
        onPageChanged: _setCurrentIndex,
        itemBuilder: (context, index) {
          final entry = list[index];
          final groupId = entry.groupId;
          final weekKey = entry.weekKey;
          final postUid = entry.postUid;
          final post = entry.post;
          final authorName = formatUserDisplayName(
            post['authorName'] ?? 'Usuario',
          );
          final authorPhotoUrl = post['authorPhotoUrl'] as String?;
          final weekLabel = obtenerEtiquetaSemana(weekKey);
          final isOwnSelfie = currentUser?.uid == postUid;
          final imageUrl = (post['imageUrl'] ?? post['thumbUrl'] ?? '')
              .toString();

          final postRef = FirebaseFirestore.instance
              .collection('groups')
              .doc(groupId)
              .collection('weeks')
              .doc(weekKey)
              .collection('posts')
              .doc(postUid);

          final reactionsRef = postRef
              .collection('reactions')
              .orderBy('updatedAt', descending: true);

          final myPostRef = currentUser == null
              ? null
              : FirebaseFirestore.instance
                    .collection('groups')
                    .doc(groupId)
                    .collection('weeks')
                    .doc(weekKey)
                    .collection('posts')
                    .doc(currentUser.uid);

          return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: reactionsRef.snapshots(),
            builder: (context, reactionsSnapshot) {
              final reactions = reactionsSnapshot.data?.docs ?? [];
              final myReaction = currentUser == null
                  ? null
                  : reactions
                        .where((doc) => doc.id == currentUser.uid)
                        .map((doc) => doc.data()['emoji'] as String?)
                        .where((emoji) => emoji != null && emoji.isNotEmpty)
                        .cast<String>()
                        .firstOrNull;

              Widget reactionPanel({
                required bool canReact,
                required String disabledMessage,
                required String actionDisabledMessage,
                bool reserveEmptySpace = false,
              }) {
                return FullScreenReactionPanel(
                  reactions: reactions,
                  myReaction: myReaction,
                  canReact: canReact,
                  isSending: sendingReaction,
                  disabledMessage: disabledMessage,
                  actionDisabledMessage: actionDisabledMessage,
                  reserveEmptySpace: reserveEmptySpace,
                  onAddReactionTap: () {
                    unawaited(
                      _openReactionPicker(
                        currentReaction: myReaction,
                        canReact: canReact,
                        unavailableMessage: actionDisabledMessage,
                        onReact: (emoji) =>
                            unawaited(_sendReaction(entry, emoji)),
                      ),
                    );
                  },
                );
              }

              final panel = currentUser == null || myPostRef == null
                  ? reactionPanel(
                      canReact: false,
                      disabledMessage: 'Inicia sesión para reaccionar',
                      actionDisabledMessage: '',
                    )
                  : StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                      stream: myPostRef.snapshots(),
                      builder: (context, myPostSnapshot) {
                        final hasPublishedThisWeek =
                            myPostSnapshot.data?.exists ?? false;
                        final isCurrentSundayWeek =
                            esDomingo() && weekKey == obtenerWeekKeyActual();
                        final canReact =
                            hasPublishedThisWeek &&
                            !isOwnSelfie &&
                            (isCurrentSundayWeek || myReaction == null);
                        final missingCurrentSundaySelfie =
                            !hasPublishedThisWeek &&
                            !isOwnSelfie &&
                            isCurrentSundayWeek;
                        return reactionPanel(
                          canReact: canReact,
                          disabledMessage: '',
                          actionDisabledMessage: missingCurrentSundaySelfie
                              ? 'Sube tu selfie semanal para poder reaccionar'
                              : '',
                          reserveEmptySpace: isOwnSelfie,
                        );
                      },
                    );

              return SafeArea(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        12,
                        ssHeaderTopPadding,
                        14,
                        0,
                      ),
                      child: _SelfieViewerHeader(
                        authorName: authorName,
                        authorPhotoUrl: authorPhotoUrl,
                        subtitle: weekLabel,
                        busy:
                            replacingProfilePhoto ||
                            downloadingSelfie ||
                            sendingReport ||
                            deletingSelfie,
                        showOptions: currentUser != null,
                        canReplaceProfilePhoto: isOwnSelfie,
                        canReport: !isOwnSelfie,
                        canDeleteSelfie: isOwnSelfie,
                        onBack: () => Navigator.pop(context),
                        onAuthorTap: () => _openAuthorSelfies(
                          entry,
                          authorName: authorName,
                          authorPhotoUrl: authorPhotoUrl,
                        ),
                        onSelected: (action) =>
                            _handleSelfieAction(action, entry),
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(18, 6, 18, 4),
                        child: FullScreenSelfieImage(
                          imageUrl: imageUrl,
                          thumbnailUrl: (post['thumbUrl'] ?? '').toString(),
                          fallbackText: initialsFromName(authorName),
                          onReactionHold: () => _handleImageReactionHold(
                            entry,
                            isOwnSelfie: isOwnSelfie,
                            currentReaction: myReaction,
                          ),
                        ),
                      ),
                    ),
                    panel,
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _SelfieViewerHeader extends StatelessWidget {
  final String authorName;
  final String? authorPhotoUrl;
  final String subtitle;
  final bool busy;
  final bool showOptions;
  final bool canReplaceProfilePhoto;
  final bool canReport;
  final bool canDeleteSelfie;
  final VoidCallback onBack;
  final VoidCallback onAuthorTap;
  final ValueChanged<_SelfieViewerAction> onSelected;

  const _SelfieViewerHeader({
    required this.authorName,
    required this.authorPhotoUrl,
    required this.subtitle,
    required this.busy,
    required this.showOptions,
    required this.canReplaceProfilePhoto,
    required this.canReport,
    required this.canDeleteSelfie,
    required this.onBack,
    required this.onAuthorTap,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: ssHeaderActionSize + ssHeaderActionTop * 2,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _SelfieHeaderBackButton(onTap: onBack),
          const SizedBox(width: 10),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onAuthorTap,
              child: Row(
                children: [
                  MiniProfileAvatar(
                    name: authorName,
                    photoUrl: authorPhotoUrl,
                    size: 38,
                    borderColor: Colors.white,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          authorName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFF17191D),
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            height: 1.02,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: ssText3,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            height: 1,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (showOptions) ...[
            const SizedBox(width: 6),
            _SelfieOptionsMenuButton(
              busy: busy,
              canReplaceProfilePhoto: canReplaceProfilePhoto,
              canReport: canReport,
              canDeleteSelfie: canDeleteSelfie,
              onSelected: onSelected,
            ),
          ],
        ],
      ),
    );
  }
}

class _SelfieHeaderBackButton extends StatelessWidget {
  final VoidCallback onTap;

  const _SelfieHeaderBackButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: ssHeaderActionSize,
      child: IconButton(
        tooltip: 'Volver',
        onPressed: onTap,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(
          width: ssHeaderActionSize,
          height: ssHeaderActionSize,
        ),
        icon: const SundayHeaderBackIcon(),
      ),
    );
  }
}

class _SelfieOptionsMenuButton extends StatelessWidget {
  final bool busy;
  final bool canReplaceProfilePhoto;
  final bool canReport;
  final bool canDeleteSelfie;
  final ValueChanged<_SelfieViewerAction> onSelected;

  const _SelfieOptionsMenuButton({
    required this.busy,
    required this.canReplaceProfilePhoto,
    required this.canReport,
    required this.canDeleteSelfie,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_SelfieViewerAction>(
      tooltip: 'Opciones',
      enabled: !busy,
      position: PopupMenuPosition.under,
      color: Colors.white,
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      onSelected: onSelected,
      itemBuilder: (context) => [
        if (canReplaceProfilePhoto)
          PopupMenuItem(
            value: _SelfieViewerAction.replaceProfilePhoto,
            child: Row(
              children: [
                const Icon(Icons.account_circle_outlined, color: ssOrangeDark),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Text(
                        'Reemplazar foto de perfil',
                        style: TextStyle(
                          color: ssText,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Ver anuncio para confirmar',
                        style: TextStyle(
                          color: ssText3,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        PopupMenuItem(
          value: _SelfieViewerAction.downloadSelfie,
          child: Row(
            children: [
              const Icon(Icons.download_rounded, color: ssOrangeDark),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Text(
                      'Descargar selfie',
                      style: TextStyle(
                        color: ssText,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Guardar en galería',
                      style: TextStyle(
                        color: ssText3,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (canReport)
          PopupMenuItem(
            value: _SelfieViewerAction.report,
            child: Row(
              children: [
                const Icon(Icons.flag_outlined, color: ssOrangeDark),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Text(
                        'Reportar selfie',
                        style: TextStyle(
                          color: ssText,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Enviar para revisión privada',
                        style: TextStyle(
                          color: ssText3,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        if (canDeleteSelfie)
          PopupMenuItem(
            value: _SelfieViewerAction.deleteSelfie,
            child: Row(
              children: [
                const Icon(
                  Icons.delete_outline_rounded,
                  color: Color(0xFFE74C3C),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Text(
                        'Borrar selfie',
                        style: TextStyle(
                          color: ssText,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Eliminar definitivamente',
                        style: TextStyle(
                          color: ssText3,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
      child: SizedBox.square(
        dimension: ssHeaderActionSize,
        child: Center(
          child: busy
              ? const Icon(
                  Icons.hourglass_top_rounded,
                  color: ssText2,
                  size: 20,
                )
              : const SundayHeaderMoreIcon(),
        ),
      ),
    );
  }
}

class FullScreenSelfieImage extends StatelessWidget {
  final String imageUrl;
  final String thumbnailUrl;
  final String fallbackText;
  final VoidCallback? onReactionHold;

  const FullScreenSelfieImage({
    super.key,
    required this.imageUrl,
    this.thumbnailUrl = '',
    required this.fallbackText,
    this.onReactionHold,
  });

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(36);
    final cleanThumbnailUrl = thumbnailUrl.trim();
    final loadingPreview =
        cleanThumbnailUrl.isEmpty || cleanThumbnailUrl == imageUrl.trim()
        ? const DecoratedBox(
            decoration: BoxDecoration(color: Color(0x33FFFFFF)),
            child: Center(child: CircularProgressIndicator(color: ssOrange)),
          )
        : CachedRemoteImage(
            imageUrl: cleanThumbnailUrl,
            cacheVariant: 'thumbnail',
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            alignment: Alignment.center,
            filterQuality: FilterQuality.high,
            loadingWidget: const DecoratedBox(
              decoration: BoxDecoration(color: Color(0x33FFFFFF)),
              child: Center(child: CircularProgressIndicator(color: ssOrange)),
            ),
            errorWidget: const DecoratedBox(
              decoration: BoxDecoration(color: Color(0x33FFFFFF)),
              child: Center(child: CircularProgressIndicator(color: ssOrange)),
            ),
          );

    final image = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.055),
            blurRadius: 24,
            offset: const Offset(0, 13),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: SizedBox(
          width: double.infinity,
          height: double.infinity,
          child: imageUrl.isEmpty
              ? _SelfieImageFallback(fallbackText: fallbackText)
              : CachedRemoteImage(
                  imageUrl: imageUrl,
                  cacheVariant: 'original',
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                  alignment: Alignment.center,
                  filterQuality: FilterQuality.high,
                  loadingWidget: loadingPreview,
                  errorWidget: _SelfieImageFallback(fallbackText: fallbackText),
                ),
        ),
      ),
    );

    final holdCallback = onReactionHold;
    if (holdCallback == null) return image;

    return _TwoSecondHoldReactionGesture(
      onTriggered: holdCallback,
      child: image,
    );
  }
}

class _TwoSecondHoldReactionGesture extends StatefulWidget {
  final Widget child;
  final VoidCallback onTriggered;

  const _TwoSecondHoldReactionGesture({
    required this.child,
    required this.onTriggered,
  });

  @override
  State<_TwoSecondHoldReactionGesture> createState() =>
      _TwoSecondHoldReactionGestureState();
}

class _TwoSecondHoldReactionGestureState
    extends State<_TwoSecondHoldReactionGesture> {
  Timer? holdTimer;
  bool triggered = false;

  void _startHold() {
    _cancelHold();
    triggered = false;
    holdTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted || triggered) return;
      triggered = true;
      HapticFeedback.selectionClick();
      widget.onTriggered();
    });
  }

  void _cancelHold() {
    holdTimer?.cancel();
    holdTimer = null;
  }

  @override
  void dispose() {
    _cancelHold();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _startHold(),
      onTapUp: (_) => _cancelHold(),
      onTapCancel: _cancelHold,
      child: widget.child,
    );
  }
}

class _SelfieImageFallback extends StatelessWidget {
  final String fallbackText;

  const _SelfieImageFallback({required this.fallbackText});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF66B8AD), Color(0xFFB9DFD7)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Container(
          width: 132,
          height: 132,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.30),
            shape: BoxShape.circle,
          ),
          child: Text(
            fallbackText,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 48,
              fontWeight: FontWeight.w900,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

class FullScreenReactionPanel extends StatelessWidget {
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> reactions;
  final String? myReaction;
  final bool canReact;
  final bool isSending;
  final String disabledMessage;
  final String actionDisabledMessage;
  final bool reserveEmptySpace;
  final VoidCallback onAddReactionTap;

  const FullScreenReactionPanel({
    super.key,
    required this.reactions,
    required this.myReaction,
    required this.canReact,
    required this.isSending,
    required this.disabledMessage,
    required this.actionDisabledMessage,
    required this.reserveEmptySpace,
    required this.onAddReactionTap,
  });

  @override
  Widget build(BuildContext context) {
    final cleanDisabledMessage = disabledMessage.trim();
    final cleanActionDisabledMessage = actionDisabledMessage.trim();
    final showReactionButton =
        canReact || cleanActionDisabledMessage.isNotEmpty;
    final visibleReactions = reactions
        .where((reaction) {
          final emoji = normalizarEmojiReaccion(
            (reaction.data()['emoji'] ?? '').toString(),
          );
          return emoji.isNotEmpty;
        })
        .toList(growable: false);

    if (visibleReactions.isEmpty &&
        !showReactionButton &&
        cleanDisabledMessage.isEmpty &&
        !reserveEmptySpace) {
      return const SizedBox.shrink();
    }

    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(18, 4, 18, math.max(8, bottomInset + 4)),
      child: Container(
        constraints: const BoxConstraints(minHeight: 54),
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(32),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.065),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          children: [
            Expanded(
              child: visibleReactions.isEmpty
                  ? _SelfieReactionDisabledMessage(
                      message: cleanDisabledMessage,
                    )
                  : SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      physics: const BouncingScrollPhysics(),
                      child: Row(
                        children: visibleReactions.map((reaction) {
                          final data = reaction.data();
                          final emoji = normalizarEmojiReaccion(
                            (data['emoji'] ?? '').toString(),
                          );
                          final name = formatUserDisplayName(
                            data['authorName'] ?? 'Usuario',
                          );
                          final photoUrl = data['authorPhotoUrl'] as String?;

                          return Padding(
                            padding: const EdgeInsets.only(right: 12),
                            child: _SelfieReactionAvatarPill(
                              name: name,
                              photoUrl: photoUrl,
                              emoji: emoji,
                              selected:
                                  reaction.id == currentUid &&
                                  myReaction == emoji,
                            ),
                          );
                        }).toList(),
                      ),
                    ),
            ),
            if (showReactionButton) ...[
              const SizedBox(width: 8),
              _SelfieAddReactionButton(
                isSending: isSending,
                onTap: onAddReactionTap,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SelfieReactionAvatarPill extends StatelessWidget {
  final String name;
  final String? photoUrl;
  final String emoji;
  final bool selected;

  const _SelfieReactionAvatarPill({
    required this.name,
    required this.photoUrl,
    required this.emoji,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      padding: const EdgeInsets.fromLTRB(6, 4, 10, 4),
      decoration: BoxDecoration(
        color: selected ? ssOrangeLight : Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: selected ? ssOrangeMid : ssBorder,
          width: 1.6,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          MiniProfileAvatar(
            name: name,
            photoUrl: photoUrl,
            size: 25,
            borderColor: Colors.white,
          ),
          const SizedBox(width: 7),
          Text(emoji, style: const TextStyle(fontSize: 19, height: 1)),
        ],
      ),
    );
  }
}

class _SelfieReactionDisabledMessage extends StatelessWidget {
  final String message;

  const _SelfieReactionDisabledMessage({required this.message});

  @override
  Widget build(BuildContext context) {
    if (message.isEmpty) return const SizedBox.shrink();

    return Text(
      message,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: ssText3,
        fontSize: 12,
        fontWeight: FontWeight.w800,
        height: 1.2,
      ),
    );
  }
}

class _SelfieAddReactionButton extends StatelessWidget {
  final bool isSending;
  final VoidCallback onTap;

  const _SelfieAddReactionButton({
    required this.isSending,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Añadir emoticono',
      child: Material(
        color: ssOrange,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: isSending ? null : onTap,
          customBorder: const CircleBorder(),
          child: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: ssOrangeDark.withValues(alpha: 0.22),
                  blurRadius: 12,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Center(
              child: isSending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.3,
                      ),
                    )
                  : const Icon(
                      Icons.add_rounded,
                      color: Colors.white,
                      size: 28,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class EmojiReactionPickerSheet extends StatefulWidget {
  final String? currentReaction;

  const EmojiReactionPickerSheet({super.key, required this.currentReaction});

  @override
  State<EmojiReactionPickerSheet> createState() =>
      _EmojiReactionPickerSheetState();
}

class _EmojiReactionPickerSheetState extends State<EmojiReactionPickerSheet> {
  late int selectedSectionIndex;
  String? expandedEmojiBase;

  @override
  void initState() {
    super.initState();
    selectedSectionIndex = _sectionIndexForEmoji(widget.currentReaction);
  }

  int _sectionIndexForEmoji(String? emoji) {
    final cleanEmoji = normalizarEmojiReaccion(emoji ?? '');
    if (cleanEmoji.isEmpty) return 0;

    for (var index = 0; index < kSundayReactionEmojiSections.length; index++) {
      if (kSundayReactionEmojiSections[index].emojis.contains(cleanEmoji)) {
        return index;
      }
    }

    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final height = math.min(MediaQuery.sizeOf(context).height * 0.76, 640.0);
    final section = kSundayReactionEmojiSections[selectedSectionIndex];
    final currentReaction = normalizarEmojiReaccion(
      widget.currentReaction ?? '',
    );
    final emojiGroups = agruparEmojisReaccion(section.emojis);
    final expandedGroup = expandedEmojiBase == null
        ? null
        : emojiGroups
              .where((group) => group.key == expandedEmojiBase)
              .firstOrNull;

    return SafeArea(
      top: false,
      child: Container(
        height: height,
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 22),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: ssBorder,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const Text(
              'Mi reacción',
              style: TextStyle(
                color: ssTitle,
                fontSize: 20,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 46,
              child: ListView.separated(
                physics: const BouncingScrollPhysics(),
                scrollDirection: Axis.horizontal,
                itemCount: kSundayReactionEmojiSections.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final option = kSundayReactionEmojiSections[index];
                  final selected = index == selectedSectionIndex;

                  return Tooltip(
                    message: option.label,
                    child: InkWell(
                      onTap: () => setState(() {
                        selectedSectionIndex = index;
                        expandedEmojiBase = null;
                      }),
                      borderRadius: BorderRadius.circular(15),
                      child: Container(
                        width: 44,
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: selected ? ssOrangeLight : ssBg,
                          borderRadius: BorderRadius.circular(15),
                          border: Border.all(
                            color: selected ? ssOrange : ssBorder,
                            width: selected ? 1.6 : 1,
                          ),
                        ),
                        child: Text(
                          option.icon,
                          style: const TextStyle(fontSize: 22, height: 1),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            Text(
              section.label,
              style: const TextStyle(
                color: ssText2,
                fontSize: 13,
                fontWeight: FontWeight.w900,
              ),
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 160),
              child: expandedGroup == null
                  ? const SizedBox(height: 8)
                  : Padding(
                      key: ValueKey(expandedGroup.key),
                      padding: const EdgeInsets.only(top: 8, bottom: 8),
                      child: SizedBox(
                        height: 44,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          physics: const BouncingScrollPhysics(),
                          itemCount: expandedGroup.variants.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 8),
                          itemBuilder: (context, index) {
                            final emoji = expandedGroup.variants[index];
                            final selected = emoji == currentReaction;

                            return InkWell(
                              onTap: () => Navigator.pop(context, emoji),
                              borderRadius: BorderRadius.circular(14),
                              child: Container(
                                width: 44,
                                height: 44,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: selected ? ssOrangeLight : ssBg,
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: selected ? ssOrange : ssBorder,
                                    width: selected ? 1.6 : 1,
                                  ),
                                ),
                                child: Text(
                                  emoji,
                                  style: const TextStyle(
                                    fontSize: 24,
                                    height: 1,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final crossAxisCount = math.max(
                    6,
                    math.min(9, (constraints.maxWidth / 46).floor()),
                  );

                  return GridView.builder(
                    key: ValueKey(section.label),
                    physics: const BouncingScrollPhysics(),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: crossAxisCount,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                    ),
                    itemCount: emojiGroups.length,
                    itemBuilder: (context, index) {
                      final group = emojiGroups[index];
                      final selected = group.variants.contains(currentReaction);
                      final hasVariants = group.variants.length > 1;
                      return InkWell(
                        onTap: () {
                          if (!hasVariants) {
                            Navigator.pop(context, group.displayEmoji);
                            return;
                          }

                          setState(() {
                            expandedEmojiBase = expandedEmojiBase == group.key
                                ? null
                                : group.key;
                          });
                        },
                        borderRadius: BorderRadius.circular(14),
                        child: Container(
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: selected ? ssOrangeLight : ssBg,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: selected ? ssOrange : ssBorder,
                              width: selected ? 1.6 : 1,
                            ),
                          ),
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Center(
                                child: Text(
                                  group.displayEmoji,
                                  style: const TextStyle(
                                    fontSize: 24,
                                    height: 1,
                                  ),
                                ),
                              ),
                              if (hasVariants)
                                const Positioned(
                                  right: 4,
                                  bottom: 3,
                                  child: Icon(
                                    Icons.expand_more_rounded,
                                    color: ssText3,
                                    size: 13,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CameraTabScreen extends StatefulWidget {
  final User user;

  const CameraTabScreen({super.key, required this.user});

  @override
  State<CameraTabScreen> createState() => _CameraTabScreenState();
}

class _CameraTabScreenState extends State<CameraTabScreen> {
  bool uploading = false;
  String? uploadingGroupId;

  void _openReplacementInfo({required String groupName}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SelfieReplacementInfoScreen(groupName: groupName),
      ),
    );
  }

  Future<void> _openCameraAndUpload({
    required String groupId,
    required String groupName,
  }) async {
    if (uploading) return;

    final window = obtenerSundayWindowState();

    if (!window.canUpload) {
      showSundaySnack(context, 'La ventana de subida está cerrada');
      return;
    }

    final foto = await Navigator.push<XFile>(
      context,
      MaterialPageRoute(
        builder: (_) => CameraCaptureScreen(groupName: groupName),
      ),
    );

    if (!mounted || foto == null) return;

    setState(() {
      uploading = true;
      uploadingGroupId = groupId;
    });

    try {
      final validPhoto = await validarFotoSelfieParaSubida(context, foto);
      if (!mounted || !validPhoto) return;

      await publicarSelfieReal(groupId: groupId, user: widget.user, foto: foto);
      if (!mounted) return;
      showSundaySnack(context, 'Selfie publicado en $groupName');
    } on SelfiePhotoValidationException catch (error) {
      if (!mounted) return;
      showSundaySnack(context, error.message);
    } catch (error) {
      if (!mounted) return;
      showSundaySnack(context, 'Error: $error');
    } finally {
      if (mounted) {
        setState(() {
          uploading = false;
          uploadingGroupId = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    SundayClockScope.watch(context);
    final groupsRef = FirebaseFirestore.instance
        .collection('users')
        .doc(widget.user.uid)
        .collection('groups')
        .orderBy('joinedAt', descending: true);

    final window = obtenerSundayWindowState();

    return Scaffold(
      backgroundColor: ssBg,
      body: SafeArea(
        child: Column(
          children: [
            const AppHeader(),
            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: groupsRef.snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(
                      child: CircularProgressIndicator(color: ssOrange),
                    );
                  }

                  final groupDocs = snapshot.data?.docs ?? [];

                  if (!window.canUpload) {
                    return CameraClosedContent(window: window);
                  }

                  if (groupDocs.isEmpty) {
                    return const CameraEmptyGroupsContent();
                  }

                  return CameraOpenContent(
                    groupDocs: groupDocs,
                    uploading: uploading,
                    uploadingGroupId: uploadingGroupId,
                    onUpload: _openCameraAndUpload,
                    onReplaceRequested: _openReplacementInfo,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CameraClosedContent extends StatelessWidget {
  final SundayWindowState window;

  const CameraClosedContent({super.key, required this.window});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
      children: [
        SizedBox(height: MediaQuery.sizeOf(context).height * 0.12),
        const WeekCalendarGraphic(),
        const SizedBox(height: 28),
        const Text(
          'Tu selfie te espera el domingo',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: ssTitle,
            fontSize: 22,
            fontWeight: FontWeight.w800,
            height: 1.15,
          ),
        ),
        const SizedBox(height: 12),
        RichText(
          textAlign: TextAlign.center,
          text: const TextSpan(
            style: TextStyle(
              color: ssText2,
              fontSize: 15,
              height: 1.6,
              fontWeight: FontWeight.w500,
            ),
            children: [
              TextSpan(
                text:
                    'Solo puedes subir tu selfie los domingos de 00:00 a 23:59 — ',
              ),
              TextSpan(
                text: 'Europe/Madrid',
                style: TextStyle(
                  color: ssOrangeDark,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        Center(child: CameraCountdownBadge(window: window)),
      ],
    );
  }
}

class CameraEmptyGroupsContent extends StatelessWidget {
  const CameraEmptyGroupsContent({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
      children: [
        SizedBox(height: MediaQuery.sizeOf(context).height * 0.12),
        const WeekCalendarGraphic(),
        const SizedBox(height: 28),
        const Text(
          'Hoy es domingo',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: ssTitle,
            fontSize: 22,
            fontWeight: FontWeight.w800,
            height: 1.15,
          ),
        ),
        const SizedBox(height: 9),
        const Text(
          '¡Sube tu Selfie!',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: ssTitle,
            fontSize: 22,
            fontWeight: FontWeight.w800,
            height: 1.15,
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Crea o únete a un grupo para poder abrir la cámara y publicar tu Sunday Selfie.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: ssText2,
            fontSize: 15,
            height: 1.6,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class CameraOpenContent extends StatelessWidget {
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> groupDocs;
  final bool uploading;
  final String? uploadingGroupId;
  final Future<void> Function({
    required String groupId,
    required String groupName,
  })
  onUpload;
  final void Function({required String groupName}) onReplaceRequested;

  const CameraOpenContent({
    super.key,
    required this.groupDocs,
    required this.uploading,
    required this.uploadingGroupId,
    required this.onUpload,
    required this.onReplaceRequested,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
      children: [
        const SizedBox(height: 0),
        const Text(
          'Hoy es domingo',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: ssTitle,
            fontSize: 22,
            fontWeight: FontWeight.w800,
            height: 1.15,
          ),
        ),
        const SizedBox(height: 9),
        const Text(
          '¡Sube tu Selfie!',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: ssTitle,
            fontSize: 22,
            fontWeight: FontWeight.w800,
            height: 1.15,
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          'Elige en qué grupo quieres publicar tu Sunday Selfie de esta semana.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: ssText2,
            fontSize: 15,
            height: 1.5,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 22),
        ...groupDocs.map((doc) {
          final data = doc.data();
          final groupId = (data['groupId'] ?? doc.id).toString();
          final groupName = (data['displayNameSnapshot'] ?? 'Grupo').toString();
          final groupPhotoUrl = nonEmptyStringOrNull(
            data['groupPhotoUrlSnapshot'],
          );
          final isUploading = uploading && uploadingGroupId == groupId;

          return CameraGroupUploadCard(
            groupId: groupId,
            groupName: groupName,
            groupPhotoUrl: groupPhotoUrl,
            uploading: isUploading,
            locked: uploading && !isUploading,
            onTap: () => onUpload(groupId: groupId, groupName: groupName),
            onReplaceRequested: () => onReplaceRequested(groupName: groupName),
          );
        }),
      ],
    );
  }
}

class CameraGroupUploadCard extends StatelessWidget {
  final String groupId;
  final String groupName;
  final String? groupPhotoUrl;
  final bool uploading;
  final bool locked;
  final VoidCallback onTap;
  final VoidCallback onReplaceRequested;

  const CameraGroupUploadCard({
    super.key,
    required this.groupId,
    required this.groupName,
    required this.groupPhotoUrl,
    required this.uploading,
    required this.locked,
    required this.onTap,
    required this.onReplaceRequested,
  });

  @override
  Widget build(BuildContext context) {
    final weekKey = obtenerWeekKeyActual();
    final postRef = FirebaseFirestore.instance
        .collection('groups')
        .doc(groupId)
        .collection('weeks')
        .doc(weekKey)
        .collection('posts')
        .doc(FirebaseAuth.instance.currentUser?.uid);

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: postRef.snapshots(),
      builder: (context, snapshot) {
        final hasSelfie = snapshot.data?.exists ?? false;
        final enabled = !locked && !uploading;

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: ssBorder),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: enabled
                  ? hasSelfie
                        ? onReplaceRequested
                        : onTap
                  : null,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    GroupIcon(name: groupName, photoUrl: groupPhotoUrl),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            formatGroupDisplayName(groupName),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: ssTitle,
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            hasSelfie
                                ? '✓ Selfie publicado'
                                : uploading
                                ? 'Publicando selfie...'
                                : 'Toca para abrir la cámara',
                            style: TextStyle(
                              color: hasSelfie ? ssOrangeDark : ssText3,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      width: hasSelfie ? 58 : 42,
                      height: hasSelfie ? 46 : 42,
                      decoration: BoxDecoration(
                        color: hasSelfie ? Colors.white : ssOrange,
                        borderRadius: BorderRadius.circular(14),
                        border: hasSelfie
                            ? Border.all(color: ssOrangeMid, width: 1.5)
                            : null,
                        boxShadow: hasSelfie
                            ? [
                                BoxShadow(
                                  color: ssOrangeDark.withValues(alpha: 0.10),
                                  blurRadius: 10,
                                  offset: const Offset(0, 3),
                                ),
                              ]
                            : null,
                      ),
                      child: uploading
                          ? const Padding(
                              padding: EdgeInsets.all(11),
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2.3,
                              ),
                            )
                          : hasSelfie
                          ? const Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.photo_camera_rounded,
                                  color: ssOrangeDark,
                                  size: 18,
                                ),
                                SizedBox(height: 1),
                                Text(
                                  'Rehacer',
                                  maxLines: 1,
                                  style: TextStyle(
                                    color: ssOrangeDark,
                                    fontSize: 9.2,
                                    fontWeight: FontWeight.w900,
                                    height: 1,
                                  ),
                                ),
                              ],
                            )
                          : const Icon(
                              Icons.photo_camera_rounded,
                              color: Colors.white,
                              size: 22,
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class SelfieReplacementInfoScreen extends StatelessWidget {
  final String groupName;

  const SelfieReplacementInfoScreen({super.key, required this.groupName});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ssBg,
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(onBack: () => Navigator.pop(context)),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
                children: [
                  Container(
                    width: 88,
                    height: 88,
                    decoration: const BoxDecoration(
                      color: ssOrangeLight,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.looks_one_rounded,
                      color: ssOrange,
                      size: 46,
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Una selfie por domingo',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: ssTitle,
                      fontSize: 28,
                      height: 1.1,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Ya has publicado tu Sunday Selfie en ${formatGroupDisplayName(groupName)}.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: ssText2,
                      fontSize: 15,
                      height: 1.45,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 26),
                  SundayCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Reemplazo excepcional',
                          style: TextStyle(
                            color: ssTitle,
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Sunday Selfie está pensado para guardar un único momento real de cada domingo.',
                          style: TextStyle(
                            color: ssText2,
                            fontSize: 14,
                            height: 1.45,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Para quienes apoyan el desarrollo de Sunday Selfie, más adelante permitiremos reemplazarla después de ver un anuncio.',
                          style: TextStyle(
                            color: ssText2,
                            fontSize: 14,
                            height: 1.45,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  SundayButton(
                    text: 'Próximamente: ver anuncio para reemplazar',
                    onPressed: () {
                      showSundaySnack(
                        context,
                        'El reemplazo mediante anuncio estará disponible próximamente',
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Conservar mi selfie actual'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CameraCountdownBadge extends StatefulWidget {
  final SundayWindowState window;

  const CameraCountdownBadge({super.key, required this.window});

  @override
  State<CameraCountdownBadge> createState() => _CameraCountdownBadgeState();
}

class _CameraCountdownBadgeState extends State<CameraCountdownBadge> {
  late Timer timer;
  late Duration remaining;

  @override
  void initState() {
    super.initState();
    remaining = obtenerTiempoRestanteVentana(widget.window);
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => remaining = obtenerTiempoRestanteVentana(widget.window));
    });
  }

  @override
  void dispose() {
    timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final days = remaining.inDays.toString().padLeft(2, '0');
    final hours = remaining.inHours.remainder(24).toString().padLeft(2, '0');
    final minutes = remaining.inMinutes
        .remainder(60)
        .toString()
        .padLeft(2, '0');
    final seconds = remaining.inSeconds
        .remainder(60)
        .toString()
        .padLeft(2, '0');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      decoration: BoxDecoration(
        color: ssOrangeLight,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ssOrangeMid, width: 1.5),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$days:$hours:$minutes:$seconds',
            style: const TextStyle(
              color: ssOrangeDark,
              fontSize: 20,
              fontWeight: FontWeight.w900,
              fontFamily: 'monospace',
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'DD:HH:MM:SS',
            style: TextStyle(
              color: ssText3,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

enum MySelfiesSortMode { newest, oldest, group, week }

enum MemberGroupSelfiesSortMode { newest, oldest }

class MySelfiesScreen extends StatefulWidget {
  final User user;

  const MySelfiesScreen({super.key, required this.user});

  @override
  State<MySelfiesScreen> createState() => _MySelfiesScreenState();
}

class _MySelfiesScreenState extends State<MySelfiesScreen> {
  MySelfiesSortMode sortMode = MySelfiesSortMode.newest;
  String filterGroup = 'all';

  bool _isDateSortMode(MySelfiesSortMode mode) {
    return mode == MySelfiesSortMode.newest || mode == MySelfiesSortMode.oldest;
  }

  Future<List<MySelfieHistoryItem>> _loadMySelfies(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> groupDocs,
  ) async {
    final firestore = FirebaseFirestore.instance;
    final List<MySelfieHistoryItem> items = [];

    for (final groupDoc in groupDocs) {
      final relationData = groupDoc.data();
      final groupId = (relationData['groupId'] ?? groupDoc.id).toString();
      final groupName = (relationData['displayNameSnapshot'] ?? 'Grupo')
          .toString();
      final groupPhotoUrl = nonEmptyStringOrNull(
        relationData['groupPhotoUrlSnapshot'],
      );

      try {
        final weeksSnapshot = await firestore
            .collection('groups')
            .doc(groupId)
            .collection('weeks')
            .orderBy('createdAt', descending: true)
            .limit(30)
            .get();

        for (final weekDoc in weeksSnapshot.docs) {
          final postDoc = await weekDoc.reference
              .collection('posts')
              .doc(widget.user.uid)
              .get();

          if (!postDoc.exists) continue;

          final postData = postDoc.data();
          if (postData == null) continue;

          final imageUrl = (postData['imageUrl'] ?? '') as String;
          if (imageUrl.isEmpty) continue;

          final weekData = weekDoc.data();
          prefetchPostPhotoCache(postData, includeOriginal: true);

          items.add(
            MySelfieHistoryItem(
              groupId: groupId,
              groupName: groupName,
              groupPhotoUrl: groupPhotoUrl,
              weekKey: weekDoc.id,
              isoYear: weekData['isoYear'] as int?,
              isoWeek: weekData['isoWeek'] as int?,
              postUid: postDoc.id,
              post: postData,
              imageUrl: imageUrl,
              thumbUrl: (postData['thumbUrl'] ?? imageUrl) as String,
              createdAt: timestampToDate(postData['createdAt']),
              updatedAt: timestampToDate(postData['updatedAt']),
            ),
          );
        }
      } catch (_) {
        // Si un grupo concreto falla por permisos/datos antiguos, no bloqueamos toda la pantalla.
      }
    }

    items.sort((a, b) => _compareByNewest(a, b));
    return items;
  }

  int _compareByNewest(MySelfieHistoryItem a, MySelfieHistoryItem b) {
    final dateA =
        a.updatedAt ?? a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final dateB =
        b.updatedAt ?? b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    return dateB.compareTo(dateA);
  }

  int _compareByOldest(MySelfieHistoryItem a, MySelfieHistoryItem b) {
    final dateA =
        a.updatedAt ?? a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final dateB =
        b.updatedAt ?? b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    return dateA.compareTo(dateB);
  }

  List<MySelfieHistoryItem> _visibleItems(List<MySelfieHistoryItem> selfies) {
    final filtered = selfies
        .where((item) => filterGroup == 'all' || item.groupName == filterGroup)
        .toList();

    switch (sortMode) {
      case MySelfiesSortMode.oldest:
        filtered.sort(_compareByOldest);
        break;
      case MySelfiesSortMode.group:
        filtered.sort((a, b) {
          final groupCompare = a.groupName.compareTo(b.groupName);
          if (groupCompare != 0) return groupCompare;
          return _compareByNewest(a, b);
        });
        break;
      case MySelfiesSortMode.week:
        filtered.sort((a, b) {
          final weekCompare = b.weekKey.compareTo(a.weekKey);
          if (weekCompare != 0) return weekCompare;
          return _compareByNewest(a, b);
        });
        break;
      case MySelfiesSortMode.newest:
        filtered.sort(_compareByNewest);
        break;
    }

    return filtered;
  }

  String get _sortLabel {
    switch (sortMode) {
      case MySelfiesSortMode.newest:
        return 'Más recientes';
      case MySelfiesSortMode.oldest:
        return 'Más antiguas';
      case MySelfiesSortMode.group:
        return 'Por grupo';
      case MySelfiesSortMode.week:
        return 'Por semana';
    }
  }

  @override
  Widget build(BuildContext context) {
    final userGroupsRef = FirebaseFirestore.instance
        .collection('users')
        .doc(widget.user.uid)
        .collection('groups')
        .orderBy('joinedAt', descending: true);

    return Scaffold(
      backgroundColor: ssBg,
      body: SafeArea(
        child: Column(
          children: [
            const AppHeader(),
            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: userGroupsRef.snapshots(),
                builder: (context, groupsSnapshot) {
                  if (groupsSnapshot.connectionState ==
                      ConnectionState.waiting) {
                    return const Center(
                      child: CircularProgressIndicator(color: ssOrange),
                    );
                  }

                  final groupDocs = groupsSnapshot.data?.docs ?? [];

                  if (groupDocs.isEmpty) {
                    return ListView(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
                      children: const [
                        HtmlLikePageTitle('Mis Sunday Selfies'),
                        SizedBox(height: 18),
                        SundayCard(
                          child: EmptyStateContent(
                            icon: Icons.grid_view_rounded,
                            title: 'Aún no tienes grupos',
                            subtitle:
                                'Crea o únete a un grupo para empezar a guardar tus Sunday Selfies.',
                          ),
                        ),
                      ],
                    );
                  }

                  return FutureBuilder<List<MySelfieHistoryItem>>(
                    future: _loadMySelfies(groupDocs),
                    builder: (context, selfiesSnapshot) {
                      final loading =
                          selfiesSnapshot.connectionState ==
                          ConnectionState.waiting;
                      final selfies = selfiesSnapshot.data ?? [];
                      final visible = _visibleItems(selfies);
                      final groupNames =
                          selfies.map((item) => item.groupName).toSet().toList()
                            ..sort();

                      return ListView(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
                        children: [
                          const HtmlLikePageTitle('Mis Sunday Selfies'),
                          const SizedBox(height: 14),
                          if (loading)
                            const SizedBox(
                              height: 280,
                              child: Center(
                                child: CircularProgressIndicator(
                                  color: ssOrange,
                                ),
                              ),
                            )
                          else if (selfies.isEmpty)
                            const SundayCard(
                              child: EmptyStateContent(
                                icon: Icons.photo_camera_back_rounded,
                                title: 'Aún no has publicado ningún selfie',
                                subtitle:
                                    'Cuando publiques tu primer Sunday Selfie aparecerá aquí automáticamente.',
                              ),
                            )
                          else ...[
                            _MySelfiesToolbar(
                              count: visible.length,
                              totalCount: selfies.length,
                              sortLabel: _sortLabel,
                              filterLabel: filterGroup == 'all'
                                  ? 'Filtrar'
                                  : filterGroup,
                              filterActive: filterGroup != 'all',
                              groupNames: groupNames,
                              sortMode: sortMode,
                              dateSortsOnly: filterGroup != 'all',
                              onSortSelected: (mode) =>
                                  setState(() => sortMode = mode),
                              onFilterSelected: (group) => setState(() {
                                filterGroup = group;
                                if (group != 'all' &&
                                    !_isDateSortMode(sortMode)) {
                                  sortMode = MySelfiesSortMode.newest;
                                }
                              }),
                            ),
                            const SizedBox(height: 18),
                            if (visible.isEmpty)
                              const SundayCard(
                                child: EmptyStateContent(
                                  icon: Icons.filter_alt_off_rounded,
                                  title: 'No hay selfies en este grupo',
                                  subtitle:
                                      'Cambia el filtro para ver otros Sunday Selfies publicados.',
                                ),
                              )
                            else if (sortMode == MySelfiesSortMode.group)
                              ..._buildGroupedSections(visible)
                            else
                              _SelfiesGrid(
                                items: visible,
                                showGroupName: filterGroup == 'all',
                                onTap: (item) =>
                                    _openSelfie(context, item, visible),
                              ),
                          ],
                        ],
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildGroupedSections(List<MySelfieHistoryItem> visible) {
    final grouped = <String, List<MySelfieHistoryItem>>{};
    for (final item in visible) {
      grouped.putIfAbsent(item.groupName, () => []).add(item);
    }

    return grouped.entries.map((entry) {
      String? groupPhotoUrl;
      for (final item in entry.value) {
        groupPhotoUrl = nonEmptyStringOrNull(item.groupPhotoUrl);
        if (groupPhotoUrl != null) break;
      }

      return Padding(
        padding: const EdgeInsets.only(bottom: 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _MySelfiesGroupAvatar(name: entry.key, photoUrl: groupPhotoUrl),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    formatGroupDisplayName(entry.key),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: ssText2,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Text(
                  '· ${entry.value.length}',
                  style: const TextStyle(
                    color: ssText3,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _SelfiesGrid(
              items: entry.value,
              showGroupName: false,
              onTap: (item) => _openSelfie(context, item, entry.value),
            ),
          ],
        ),
      );
    }).toList();
  }

  void _openSelfie(
    BuildContext context,
    MySelfieHistoryItem item,
    List<MySelfieHistoryItem> galleryItems,
  ) {
    final initialIndex = galleryItems.indexWhere(
      (candidate) =>
          candidate.groupId == item.groupId &&
          candidate.weekKey == item.weekKey &&
          candidate.postUid == item.postUid,
    );

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SelfieFullScreen(
          groupId: item.groupId,
          groupName: item.groupName,
          groupPhotoUrl: item.groupPhotoUrl,
          weekKey: item.weekKey,
          postUid: item.postUid,
          post: item.post,
          initialIndex: initialIndex < 0 ? 0 : initialIndex,
          galleryEntries: galleryItems.map((candidate) {
            return SelfieViewerEntry(
              groupId: candidate.groupId,
              groupName: candidate.groupName,
              groupPhotoUrl: candidate.groupPhotoUrl,
              weekKey: candidate.weekKey,
              postUid: candidate.postUid,
              post: candidate.post,
            );
          }).toList(),
        ),
      ),
    );
  }
}

class GroupMemberSelfiesScreen extends StatefulWidget {
  final String groupId;
  final String groupName;
  final String? groupPhotoUrl;
  final String memberUid;
  final String memberName;
  final String? memberPhotoUrl;

  const GroupMemberSelfiesScreen({
    super.key,
    required this.groupId,
    required this.groupName,
    required this.groupPhotoUrl,
    required this.memberUid,
    required this.memberName,
    required this.memberPhotoUrl,
  });

  @override
  State<GroupMemberSelfiesScreen> createState() =>
      _GroupMemberSelfiesScreenState();
}

class _GroupMemberSelfiesScreenState extends State<GroupMemberSelfiesScreen> {
  MemberGroupSelfiesSortMode sortMode = MemberGroupSelfiesSortMode.newest;
  late Future<List<MySelfieHistoryItem>> selfiesFuture;

  @override
  void initState() {
    super.initState();
    selfiesFuture = _loadMemberSelfies();
  }

  @override
  void didUpdateWidget(covariant GroupMemberSelfiesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.groupId != widget.groupId ||
        oldWidget.memberUid != widget.memberUid) {
      selfiesFuture = _loadMemberSelfies();
    }
  }

  DateTime _sortableDate(MySelfieHistoryItem item) {
    return item.updatedAt ??
        item.createdAt ??
        DateTime.fromMillisecondsSinceEpoch(0);
  }

  int _compareByNewest(MySelfieHistoryItem a, MySelfieHistoryItem b) {
    return _sortableDate(b).compareTo(_sortableDate(a));
  }

  int _compareByOldest(MySelfieHistoryItem a, MySelfieHistoryItem b) {
    return _sortableDate(a).compareTo(_sortableDate(b));
  }

  List<MySelfieHistoryItem> _sortedItems(List<MySelfieHistoryItem> selfies) {
    final items = [...selfies];
    switch (sortMode) {
      case MemberGroupSelfiesSortMode.oldest:
        items.sort(_compareByOldest);
        break;
      case MemberGroupSelfiesSortMode.newest:
        items.sort(_compareByNewest);
        break;
    }
    return items;
  }

  String get _sortLabel {
    switch (sortMode) {
      case MemberGroupSelfiesSortMode.newest:
        return 'Más recientes';
      case MemberGroupSelfiesSortMode.oldest:
        return 'Anteriores';
    }
  }

  Future<List<MySelfieHistoryItem>> _loadMemberSelfies() async {
    final groupRef = FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.groupId);
    final groupSnapshot = await groupRef.get();
    final groupData = groupSnapshot.data();

    if (!groupSnapshot.exists || groupData?['deleted'] == true) {
      throw Exception('Este grupo ya no está disponible');
    }

    final groupName = formatGroupDisplayName(
      (groupData?['name'] ?? widget.groupName).toString(),
    );
    final groupPhotoUrl =
        nonEmptyStringOrNull(groupData?['photoUrl']) ??
        nonEmptyStringOrNull(widget.groupPhotoUrl);

    final weeksSnapshot = await groupRef
        .collection('weeks')
        .orderBy('createdAt', descending: true)
        .get();
    final items = <MySelfieHistoryItem>[];

    for (final weekDoc in weeksSnapshot.docs) {
      final postDoc = await weekDoc.reference
          .collection('posts')
          .doc(widget.memberUid)
          .get();

      if (!postDoc.exists) continue;

      final postData = postDoc.data();
      if (postData == null) continue;

      final imageUrl = (postData['imageUrl'] ?? '').toString();
      if (imageUrl.isEmpty) continue;

      final weekData = weekDoc.data();
      prefetchPostPhotoCache(postData, includeOriginal: true);
      items.add(
        MySelfieHistoryItem(
          groupId: widget.groupId,
          groupName: groupName,
          groupPhotoUrl: groupPhotoUrl,
          weekKey: weekDoc.id,
          isoYear: weekData['isoYear'] as int?,
          isoWeek: weekData['isoWeek'] as int?,
          postUid: postDoc.id,
          post: postData,
          imageUrl: imageUrl,
          thumbUrl: (postData['thumbUrl'] ?? imageUrl).toString(),
          createdAt: timestampToDate(postData['createdAt']),
          updatedAt: timestampToDate(postData['updatedAt']),
        ),
      );
    }

    items.sort(_compareByNewest);
    return items;
  }

  void _openSelfie(
    BuildContext context,
    MySelfieHistoryItem item,
    List<MySelfieHistoryItem> galleryItems,
  ) {
    final initialIndex = galleryItems.indexWhere(
      (candidate) =>
          candidate.groupId == item.groupId &&
          candidate.weekKey == item.weekKey &&
          candidate.postUid == item.postUid,
    );

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SelfieFullScreen(
          groupId: item.groupId,
          groupName: item.groupName,
          groupPhotoUrl: item.groupPhotoUrl,
          weekKey: item.weekKey,
          postUid: item.postUid,
          post: item.post,
          initialIndex: initialIndex < 0 ? 0 : initialIndex,
          galleryEntries: galleryItems.map((candidate) {
            return SelfieViewerEntry(
              groupId: candidate.groupId,
              groupName: candidate.groupName,
              groupPhotoUrl: candidate.groupPhotoUrl,
              weekKey: candidate.weekKey,
              postUid: candidate.postUid,
              post: candidate.post,
            );
          }).toList(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final displayName = formatUserDisplayName(widget.memberName);

    return Scaffold(
      backgroundColor: ssBg,
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(onBack: () => Navigator.pop(context)),
            Expanded(
              child: FutureBuilder<List<MySelfieHistoryItem>>(
                future: selfiesFuture,
                builder: (context, snapshot) {
                  final loading =
                      snapshot.connectionState == ConnectionState.waiting;
                  final selfies = snapshot.data ?? [];
                  final visible = _sortedItems(selfies);

                  return ListView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          MiniProfileAvatar(
                            name: displayName,
                            photoUrl: widget.memberPhotoUrl,
                            size: 42,
                            borderColor: ssBg,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Sunday selfies de $displayName',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: ssTitle,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w800,
                                    height: 1.12,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  formatGroupDisplayName(widget.groupName),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: ssText3,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    height: 1.1,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      if (loading)
                        const SizedBox(
                          height: 280,
                          child: Center(
                            child: CircularProgressIndicator(color: ssOrange),
                          ),
                        )
                      else if (snapshot.hasError)
                        SundayCard(
                          child: EmptyStateContent(
                            icon: Icons.error_outline_rounded,
                            title: 'No se pudieron cargar los selfies',
                            subtitle: '${snapshot.error}',
                          ),
                        )
                      else if (selfies.isEmpty)
                        SundayCard(
                          child: EmptyStateContent(
                            icon: Icons.photo_camera_back_rounded,
                            title: 'Aún no hay selfies',
                            subtitle:
                                '$displayName todavía no ha publicado selfies en este grupo.',
                          ),
                        )
                      else ...[
                        _MemberGroupSelfiesToolbar(
                          count: visible.length,
                          sortLabel: _sortLabel,
                          sortMode: sortMode,
                          onSortSelected: (mode) =>
                              setState(() => sortMode = mode),
                        ),
                        const SizedBox(height: 18),
                        _SelfiesGrid(
                          items: visible,
                          showGroupName: false,
                          onTap: (item) => _openSelfie(context, item, visible),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MemberGroupSelfiesToolbar extends StatelessWidget {
  final int count;
  final String sortLabel;
  final MemberGroupSelfiesSortMode sortMode;
  final ValueChanged<MemberGroupSelfiesSortMode> onSortSelected;

  const _MemberGroupSelfiesToolbar({
    required this.count,
    required this.sortLabel,
    required this.sortMode,
    required this.onSortSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            '$count Sunday Selfie${count == 1 ? '' : 's'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: ssText3,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        const SizedBox(width: 8),
        _MemberGroupSelfiesSortPill(
          label: sortLabel,
          selected: sortMode,
          onSelected: onSortSelected,
        ),
      ],
    );
  }
}

class _MemberGroupSelfiesSortPill extends StatelessWidget {
  final String label;
  final MemberGroupSelfiesSortMode selected;
  final ValueChanged<MemberGroupSelfiesSortMode> onSelected;

  const _MemberGroupSelfiesSortPill({
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<MemberGroupSelfiesSortMode>(
      tooltip: 'Ordenar',
      onSelected: onSelected,
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: MemberGroupSelfiesSortMode.newest,
          child: Text('Más recientes'),
        ),
        PopupMenuItem(
          value: MemberGroupSelfiesSortMode.oldest,
          child: Text('Anteriores'),
        ),
      ],
      child: _ToolbarPill(
        active: true,
        icon: Icons.swap_vert_rounded,
        label: label,
      ),
    );
  }
}

class _MySelfiesGroupAvatar extends StatelessWidget {
  final String name;
  final String? photoUrl;

  const _MySelfiesGroupAvatar({required this.name, required this.photoUrl});

  @override
  Widget build(BuildContext context) {
    final resolvedPhotoUrl = nonEmptyStringOrNull(photoUrl);

    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: resolvedPhotoUrl == null ? ssOrangeLight : Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: ssBorder, width: 1.2),
      ),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      child: resolvedPhotoUrl == null
          ? _MySelfiesGroupAvatarFallback(name: name)
          : CachedRemoteImage(
              imageUrl: resolvedPhotoUrl,
              cacheVariant: 'avatar',
              width: 20,
              height: 20,
              fit: BoxFit.cover,
              alignment: Alignment.center,
              filterQuality: FilterQuality.high,
              errorWidget: _MySelfiesGroupAvatarFallback(name: name),
              loadingWidget: _MySelfiesGroupAvatarFallback(name: name),
            ),
    );
  }
}

class _MySelfiesGroupAvatarFallback extends StatelessWidget {
  final String name;

  const _MySelfiesGroupAvatarFallback({required this.name});

  @override
  Widget build(BuildContext context) {
    final emoji = extractLastEmoji(name);

    return Text(
      emoji ?? initialsFromName(name),
      style: TextStyle(
        color: ssOrangeDark,
        fontSize: emoji == null ? 8 : 10,
        fontWeight: FontWeight.w900,
        height: 1,
      ),
    );
  }
}

class HtmlLikePageTitle extends StatelessWidget {
  final String text;

  const HtmlLikePageTitle(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: ssTitle,
        fontSize: 22,
        fontWeight: FontWeight.w800,
        height: 1.15,
      ),
    );
  }
}

class _MySelfiesToolbar extends StatelessWidget {
  final int count;
  final int totalCount;
  final String sortLabel;
  final String filterLabel;
  final bool filterActive;
  final List<String> groupNames;
  final MySelfiesSortMode sortMode;
  final bool dateSortsOnly;
  final ValueChanged<MySelfiesSortMode> onSortSelected;
  final ValueChanged<String> onFilterSelected;

  const _MySelfiesToolbar({
    required this.count,
    required this.totalCount,
    required this.sortLabel,
    required this.filterLabel,
    required this.filterActive,
    required this.groupNames,
    required this.sortMode,
    required this.dateSortsOnly,
    required this.onSortSelected,
    required this.onFilterSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Text(
            '$count Sunday Selfie${count == 1 ? '' : 's'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: ssText3,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        const SizedBox(width: 8),
        _SortPill(
          label: sortLabel,
          selected: sortMode,
          dateSortsOnly: dateSortsOnly,
          onSelected: onSortSelected,
        ),
        const SizedBox(width: 8),
        _FilterPill(
          label: filterLabel,
          active: filterActive,
          groupNames: groupNames,
          onSelected: onFilterSelected,
        ),
      ],
    );
  }
}

class _SortPill extends StatelessWidget {
  final String label;
  final MySelfiesSortMode selected;
  final bool dateSortsOnly;
  final ValueChanged<MySelfiesSortMode> onSelected;

  const _SortPill({
    required this.label,
    required this.selected,
    required this.dateSortsOnly,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<MySelfiesSortMode>(
      tooltip: 'Ordenar',
      onSelected: onSelected,
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: MySelfiesSortMode.newest,
          child: Text('Más recientes'),
        ),
        const PopupMenuItem(
          value: MySelfiesSortMode.oldest,
          child: Text('Más antiguas'),
        ),
        if (!dateSortsOnly) ...const [
          PopupMenuItem(
            value: MySelfiesSortMode.group,
            child: Text('Por grupo'),
          ),
          PopupMenuItem(
            value: MySelfiesSortMode.week,
            child: Text('Por semana'),
          ),
        ],
      ],
      child: _ToolbarPill(
        active: true,
        icon: Icons.swap_vert_rounded,
        label: label,
      ),
    );
  }
}

class _FilterPill extends StatelessWidget {
  final String label;
  final bool active;
  final List<String> groupNames;
  final ValueChanged<String> onSelected;

  const _FilterPill({
    required this.label,
    required this.active,
    required this.groupNames,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Filtrar',
      onSelected: onSelected,
      itemBuilder: (context) => [
        const PopupMenuItem(value: 'all', child: Text('Todos los grupos')),
        ...groupNames.map(
          (group) => PopupMenuItem(value: group, child: Text(group)),
        ),
      ],
      child: _ToolbarPill(
        active: active,
        icon: Icons.filter_alt_outlined,
        label: label,
      ),
    );
  }
}

class _ToolbarPill extends StatelessWidget {
  final bool active;
  final IconData icon;
  final String label;

  const _ToolbarPill({
    required this.active,
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: active ? ssOrangeLight : Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: active ? ssOrangeMid : ssBorder, width: 1.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: active ? ssOrangeDark : ssText2),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 92),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: active ? ssOrangeDark : ssText2,
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SelfiesGrid extends StatelessWidget {
  final List<MySelfieHistoryItem> items;
  final bool showGroupName;
  final ValueChanged<MySelfieHistoryItem> onTap;

  const _SelfiesGrid({
    required this.items,
    this.showGroupName = true,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      itemCount: items.length,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 3 / 4,
      ),
      itemBuilder: (context, index) {
        final item = items[index];
        return MySelfieHistoryCard(
          item: item,
          showGroupName: showGroupName,
          onTap: () => onTap(item),
        );
      },
    );
  }
}

class MySelfieHistoryItem {
  final String groupId;
  final String groupName;
  final String? groupPhotoUrl;
  final String weekKey;
  final int? isoYear;
  final int? isoWeek;
  final String postUid;
  final Map<String, dynamic> post;
  final String imageUrl;
  final String thumbUrl;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const MySelfieHistoryItem({
    required this.groupId,
    required this.groupName,
    required this.groupPhotoUrl,
    required this.weekKey,
    required this.isoYear,
    required this.isoWeek,
    required this.postUid,
    required this.post,
    required this.imageUrl,
    required this.thumbUrl,
    required this.createdAt,
    required this.updatedAt,
  });

  String get weekLabel {
    if (isoWeek != null && isoYear != null) {
      return 'Semana ${isoWeek.toString().padLeft(2, '0')} / $isoYear';
    }
    return obtenerEtiquetaSemana(weekKey);
  }

  String get shortWeekLabel {
    if (isoWeek != null && isoYear != null) {
      return 'Sem ${isoWeek.toString()} · $isoYear';
    }
    return weekKey;
  }

  String get dateLabel {
    final date = updatedAt ?? createdAt;
    if (date == null) return 'Publicado';
    return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
  }
}

class MySelfieHeroCard extends StatelessWidget {
  final MySelfieHistoryItem item;
  final VoidCallback onTap;

  const MySelfieHeroCard({super.key, required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 285,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(30),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.13),
              blurRadius: 24,
              offset: const Offset(0, 14),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(30),
          child: Stack(
            fit: StackFit.expand,
            children: [
              CachedRemoteImage(
                imageUrl: item.thumbUrl,
                cacheVariant: 'thumbnail',
                fit: BoxFit.cover,
                loadingWidget: const _ImageLoadingFill(),
                errorWidget: const _ImageErrorFill(),
              ),
              const _PhotoGradientOverlay(),
              Positioned(
                left: 18,
                right: 18,
                top: 18,
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.90),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Text(
                        'Última selfie',
                        style: TextStyle(
                          color: ssText,
                          fontSize: 12,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    const Spacer(),
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.92),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(
                        Icons.open_in_full_rounded,
                        color: ssText,
                        size: 18,
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                left: 18,
                right: 18,
                bottom: 18,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.groupName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.w900,
                        height: 1.05,
                      ),
                    ),
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        _OverlayPill(text: item.weekLabel),
                        const SizedBox(width: 8),
                        _OverlayPill(text: item.dateLabel),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MySelfieHistoryCard extends StatelessWidget {
  final MySelfieHistoryItem item;
  final bool showGroupName;
  final VoidCallback onTap;

  const MySelfieHistoryCard({
    super.key,
    required this.item,
    this.showGroupName = true,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          fit: StackFit.expand,
          children: [
            CachedRemoteImage(
              imageUrl: item.thumbUrl,
              cacheVariant: 'thumbnail',
              fit: BoxFit.cover,
              loadingWidget: const _ImageLoadingFill(),
              errorWidget: const _ImageErrorFill(),
            ),
            const _PhotoGradientOverlay(),
            if (showGroupName)
              Positioned(
                left: 10,
                right: 10,
                bottom: 10,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      formatGroupDisplayName(item.groupName),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        height: 1.1,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PhotoGradientOverlay extends StatelessWidget {
  const _PhotoGradientOverlay();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.06),
            Colors.black.withValues(alpha: 0.10),
            Colors.black.withValues(alpha: 0.62),
          ],
          stops: const [0.0, 0.45, 1.0],
        ),
      ),
    );
  }
}

class _OverlayPill extends StatelessWidget {
  final String text;

  const _OverlayPill({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: ssText,
          fontSize: 11,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _ImageLoadingFill extends StatelessWidget {
  const _ImageLoadingFill();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: ssOrangeLight,
      alignment: Alignment.center,
      child: const SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(color: ssOrange, strokeWidth: 2.4),
      ),
    );
  }
}

class _ImageErrorFill extends StatelessWidget {
  const _ImageErrorFill();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: ssOrangeLight,
      alignment: Alignment.center,
      child: const Icon(Icons.broken_image_rounded, color: ssOrangeDark),
    );
  }
}

class EmptyStateContent extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const EmptyStateContent({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Column(
        children: [
          Icon(icon, color: ssOrange, size: 42),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: ssText,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(color: ssText2, fontSize: 14, height: 1.35),
          ),
        ],
      ),
    );
  }
}

DateTime? timestampToDate(dynamic value) {
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  return null;
}

String formatShortDate(DateTime? date) {
  if (date == null) return '-';

  return "${date.day.toString().padLeft(2, '0')}/"
      "${date.month.toString().padLeft(2, '0')}/"
      "${date.year}";
}

class MontageScreen extends StatefulWidget {
  final User user;

  const MontageScreen({super.key, required this.user});

  @override
  State<MontageScreen> createState() => _MontageScreenState();
}

class _MontageScreenState extends State<MontageScreen> {
  int selectedGroupIndex = 0;
  int montageShuffleSeed = 0;
  String? selectedMontageWeekKey;
  MontageStyle selectedMontageStyle = MontageStyle.classic;
  bool exportingMontage = false;
  bool preparingMontageAction = false;
  final GlobalKey montageBoundaryKey = GlobalKey();

  Future<XFile?> _captureMontageFile({
    required BuildContext context,
    required String groupName,
    required String weekKey,
  }) async {
    if (mounted) {
      setState(() => exportingMontage = true);
    }

    try {
      await WidgetsBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 30));

      final boundary =
          montageBoundaryKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;

      if (boundary == null) {
        if (context.mounted) {
          showSundaySnack(context, 'No se pudo preparar el montaje');
        }
        return null;
      }

      final image = await boundary.toImage(pixelRatio: 3);
      final byteData = await image.toByteData(format: ImageByteFormat.png);

      if (byteData == null) {
        if (context.mounted) {
          showSundaySnack(context, 'No se pudo generar la imagen del montaje');
        }
        return null;
      }

      final bytes = byteData.buffer.asUint8List();
      final safeGroupName = formatGroupDisplayName(groupName)
          .replaceAll(RegExp(r'[^A-Za-z0-9_\-]+'), '_')
          .replaceAll(RegExp(r'_+'), '_')
          .trim();
      final fileName =
          'montaje_${safeGroupName.isEmpty ? 'grupo' : safeGroupName}_$weekKey.png';
      final file = File('${Directory.systemTemp.path}/$fileName');
      await file.writeAsBytes(bytes, flush: true);

      return XFile(file.path, mimeType: 'image/png', name: fileName);
    } finally {
      if (mounted) {
        setState(() => exportingMontage = false);
      }
    }
  }

  Future<void> _shareMontage({
    required BuildContext context,
    required String groupName,
    required String weekKey,
  }) async {
    if (preparingMontageAction) return;
    setState(() => preparingMontageAction = true);
    try {
      final unlocked = await prepararMontajeConAnuncio(
        context,
        accion: 'compartir',
      );
      if (!mounted || !context.mounted || !unlocked) return;

      final file = await _captureMontageFile(
        context: context,
        groupName: groupName,
        weekKey: weekKey,
      );

      if (file == null) return;
      await SharePlus.instance.share(
        ShareParams(
          files: [file],
          text:
              'Montaje Sunday Selfie de ${formatGroupDisplayName(groupName)} · ${obtenerEtiquetaSemana(weekKey)}',
          subject: 'Montaje Sunday Selfie',
          sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1),
        ),
      );
    } finally {
      if (mounted) setState(() => preparingMontageAction = false);
    }
  }

  Future<void> _downloadMontage({
    required BuildContext context,
    required String groupName,
    required String weekKey,
  }) async {
    if (preparingMontageAction) return;
    setState(() => preparingMontageAction = true);
    try {
      final unlocked = await prepararMontajeConAnuncio(
        context,
        accion: 'descargar',
      );
      if (!mounted || !context.mounted || !unlocked) return;

      showSundaySnack(context, 'Guardando montaje...');

      final file = await _captureMontageFile(
        context: context,
        groupName: groupName,
        weekKey: weekKey,
      );

      if (file == null) return;

      final savedCount = await guardarArchivosDescargadosEnTelefono(
        files: [file],
      );

      if (!context.mounted) return;
      showSundaySnack(
        context,
        savedCount == 0
            ? 'No se pudo guardar el montaje'
            : 'Montaje guardado en el teléfono',
      );
    } catch (error) {
      if (!context.mounted) return;
      final message = mensajeErrorGuardandoArchivos(error);
      showSundaySnack(
        context,
        message.contains('Fotos')
            ? message
            : 'No se pudo guardar el montaje en el teléfono',
      );
    } finally {
      if (mounted) setState(() => preparingMontageAction = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final userGroupsRef = FirebaseFirestore.instance
        .collection('users')
        .doc(widget.user.uid)
        .collection('groups')
        .orderBy('joinedAt', descending: true);

    return Scaffold(
      backgroundColor: ssBg,
      body: SafeArea(
        child: Column(
          children: [
            const AppHeader(),
            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: userGroupsRef.snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(
                      child: CircularProgressIndicator(color: ssOrange),
                    );
                  }

                  final groupDocs = snapshot.data?.docs ?? [];
                  if (groupDocs.isEmpty) {
                    return ListView(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
                      children: [
                        SundayCard(
                          child: EmptyStateContent(
                            icon: Icons.auto_awesome_rounded,
                            title: 'Aún no hay grupos',
                            subtitle:
                                'Crea o únete a un grupo para preparar montajes semanales.',
                          ),
                        ),
                      ],
                    );
                  }

                  if (selectedGroupIndex >= groupDocs.length) {
                    selectedGroupIndex = 0;
                  }

                  final selectedDoc = groupDocs[selectedGroupIndex];
                  final selectedData = selectedDoc.data();
                  final groupId = (selectedData['groupId'] ?? selectedDoc.id)
                      .toString();
                  final groupName =
                      (selectedData['displayNameSnapshot'] ?? 'Grupo')
                          .toString();
                  final groupRef = FirebaseFirestore.instance
                      .collection('groups')
                      .doc(groupId);

                  return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                    stream: groupRef.snapshots(),
                    builder: (context, groupSnapshot) {
                      final groupData =
                          groupSnapshot.data?.data() ??
                          const <String, dynamic>{};
                      final effectiveGroupName =
                          (groupData['name'] ?? groupName).toString();
                      final groupCreatedAt =
                          groupData['createdAt'] ?? selectedData['joinedAt'];
                      final memberCountRaw = groupData['memberCount'] ?? 0;
                      final memberCount = memberCountRaw is int
                          ? memberCountRaw
                          : int.tryParse('$memberCountRaw') ?? 0;
                      final weeksRef = groupRef
                          .collection('weeks')
                          .orderBy('createdAt', descending: true);

                      return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                        stream: weeksRef.snapshots(),
                        builder: (context, weeksSnapshot) {
                          final weekDocs = weeksSnapshot.data?.docs ?? [];
                          final weekKeys = obtenerWeekKeysCalendarioGrupo(
                            groupCreatedAt: groupCreatedAt,
                            existingWeekKeys: weekDocs.map((doc) => doc.id),
                          );
                          final calendarEntries =
                              construirEntradasCalendarioSemanas(
                                weekKeys: weekKeys,
                                weekDocs: weekDocs,
                                memberCount: memberCount,
                              );

                          if (weekKeys.isEmpty) {
                            selectedMontageWeekKey = null;
                            return ListView(
                              padding: EdgeInsets.zero,
                              children: [
                                _MontageGroupSelector(
                                  groupDocs: groupDocs,
                                  selectedGroupIndex: selectedGroupIndex,
                                  onSelected: (index) => setState(() {
                                    selectedGroupIndex = index;
                                    selectedMontageWeekKey = null;
                                    montageShuffleSeed = 0;
                                  }),
                                ),
                                const Padding(
                                  padding: EdgeInsets.fromLTRB(16, 42, 16, 28),
                                  child: SundayCard(
                                    child: EmptyStateContent(
                                      icon: Icons.photo_library_outlined,
                                      title: 'Aún no hay semanas anteriores',
                                      subtitle:
                                          'Cuando haya publicaciones de domingos anteriores aparecerán aquí.',
                                    ),
                                  ),
                                ),
                              ],
                            );
                          }

                          if (selectedMontageWeekKey == null ||
                              !weekKeys.contains(selectedMontageWeekKey)) {
                            selectedMontageWeekKey = weekKeys.first;
                          }

                          final weekSelectorItems =
                              construirItemsSelectorSemanas(weekKeys);
                          final weekKey = selectedMontageWeekKey!;
                          final postsRef = groupRef
                              .collection('weeks')
                              .doc(weekKey)
                              .collection('posts')
                              .orderBy('createdAt', descending: true);

                          return ListView(
                            padding: EdgeInsets.zero,
                            children: [
                              Container(
                                color: ssBg,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    _MontageGroupSelector(
                                      groupDocs: groupDocs,
                                      selectedGroupIndex: selectedGroupIndex,
                                      onSelected: (index) => setState(() {
                                        selectedGroupIndex = index;
                                        selectedMontageWeekKey = null;
                                        montageShuffleSeed = 0;
                                      }),
                                    ),
                                    SizedBox(
                                      height: 37,
                                      child: Row(
                                        children: [
                                          Padding(
                                            padding: const EdgeInsets.fromLTRB(
                                              16,
                                              6,
                                              0,
                                              6,
                                            ),
                                            child: WeekCalendarButton(
                                              onTap: () async {
                                                final selected =
                                                    await showWeekCalendarSheet(
                                                      context: context,
                                                      entries: calendarEntries,
                                                      selectedWeekKey:
                                                          selectedMontageWeekKey ??
                                                          '',
                                                    );

                                                if (!mounted ||
                                                    selected == null) {
                                                  return;
                                                }

                                                setState(() {
                                                  selectedMontageWeekKey =
                                                      selected;
                                                  montageShuffleSeed = 0;
                                                });
                                              },
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: ListView.separated(
                                              scrollDirection: Axis.horizontal,
                                              padding:
                                                  const EdgeInsets.fromLTRB(
                                                    0,
                                                    6,
                                                    16,
                                                    6,
                                                  ),
                                              itemCount:
                                                  weekSelectorItems.length,
                                              separatorBuilder: (_, _) =>
                                                  const SizedBox(width: 8),
                                              itemBuilder: (context, index) {
                                                final item =
                                                    weekSelectorItems[index];
                                                if (item.startsWith('year:')) {
                                                  return WeekYearSeparatorChip(
                                                    year: item.substring(5),
                                                  );
                                                }

                                                final key = item.substring(5);
                                                final selected =
                                                    key ==
                                                    selectedMontageWeekKey;
                                                return MontageWeekChip(
                                                  key: ValueKey(
                                                    'montage_week_${key}_$selected',
                                                  ),
                                                  label:
                                                      obtenerEtiquetaSemanaCorta(
                                                        key,
                                                      ),
                                                  selected: selected,
                                                  onTap: () => setState(() {
                                                    selectedMontageWeekKey =
                                                        key;
                                                    montageShuffleSeed = 0;
                                                  }),
                                                );
                                              },
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    FutureBuilder<
                                      QuerySnapshot<Map<String, dynamic>>
                                    >(
                                      future: postsRef.get(),
                                      builder: (context, postsSnapshot) {
                                        if (postsSnapshot.connectionState ==
                                            ConnectionState.waiting) {
                                          return const Padding(
                                            padding: EdgeInsets.only(top: 80),
                                            child: Center(
                                              child: CircularProgressIndicator(
                                                color: ssOrange,
                                              ),
                                            ),
                                          );
                                        }

                                        final posts =
                                            postsSnapshot.data?.docs ?? [];
                                        for (final postDoc in posts) {
                                          prefetchPostPhotoCache(
                                            postDoc.data(),
                                          );
                                        }
                                        if (posts.isEmpty) {
                                          return const Padding(
                                            padding: EdgeInsets.fromLTRB(
                                              16,
                                              42,
                                              16,
                                              28,
                                            ),
                                            child: SundayCard(
                                              child: EmptyStateContent(
                                                icon: Icons
                                                    .photo_library_outlined,
                                                title:
                                                    'Aún no hay selfies esta semana',
                                                subtitle:
                                                    'El montaje se completará cuando el grupo tenga publicaciones.',
                                              ),
                                            ),
                                          );
                                        }

                                        return Padding(
                                          padding: const EdgeInsets.fromLTRB(
                                            16,
                                            0,
                                            16,
                                            28,
                                          ),
                                          child: Column(
                                            children: [
                                              RepaintBoundary(
                                                key: montageBoundaryKey,
                                                child: MontagePoster(
                                                  posts: posts,
                                                  groupName: effectiveGroupName,
                                                  weekKey: weekKey,
                                                  shuffleSeed:
                                                      montageShuffleSeed,
                                                  style: selectedMontageStyle,
                                                  showEditingControls:
                                                      !exportingMontage,
                                                ),
                                              ),
                                              const SizedBox(height: 18),
                                              MontageStyleSelector(
                                                selectedStyle:
                                                    selectedMontageStyle,
                                                onSelected: (style) =>
                                                    setState(() {
                                                      selectedMontageStyle =
                                                          style;
                                                    }),
                                              ),
                                              const SizedBox(height: 10),
                                              if (posts.length > 1)
                                                OutlinedButton.icon(
                                                  onPressed:
                                                      preparingMontageAction
                                                      ? null
                                                      : () => setState(() {
                                                          montageShuffleSeed =
                                                              DateTime.now()
                                                                  .millisecondsSinceEpoch;
                                                          selectedMontageStyle =
                                                              MontageStyle
                                                                  .values[montageShuffleSeed %
                                                                  MontageStyle
                                                                      .values
                                                                      .length];
                                                        }),
                                                  icon: const Icon(
                                                    Icons.auto_awesome_rounded,
                                                    size: 18,
                                                  ),
                                                  label: const Text(
                                                    'Sorpréndeme',
                                                  ),
                                                  style: OutlinedButton.styleFrom(
                                                    minimumSize:
                                                        const Size.fromHeight(
                                                          48,
                                                        ),
                                                    foregroundColor:
                                                        ssOrangeDark,
                                                    side: const BorderSide(
                                                      color: ssOrangeMid,
                                                      width: 1.5,
                                                    ),
                                                    shape: RoundedRectangleBorder(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            14,
                                                          ),
                                                    ),
                                                  ),
                                                ),
                                              if (posts.length > 1)
                                                const SizedBox(height: 10),
                                              Row(
                                                children: [
                                                  Expanded(
                                                    child: SundayButton(
                                                      text: 'Compartir',
                                                      onPressed:
                                                          preparingMontageAction
                                                          ? null
                                                          : () => _shareMontage(
                                                              context: context,
                                                              groupName:
                                                                  effectiveGroupName,
                                                              weekKey: weekKey,
                                                            ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 10),
                                                  Expanded(
                                                    child: SundayButton(
                                                      text: 'Descargar',
                                                      variant:
                                                          SundayButtonVariant
                                                              .outline,
                                                      onPressed:
                                                          preparingMontageAction
                                                          ? null
                                                          : () => _downloadMontage(
                                                              context: context,
                                                              groupName:
                                                                  effectiveGroupName,
                                                              weekKey: weekKey,
                                                            ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ),
                                        );
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          );
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MontageGroupSelector extends StatelessWidget {
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> groupDocs;
  final int selectedGroupIndex;
  final ValueChanged<int> onSelected;

  const _MontageGroupSelector({
    required this.groupDocs,
    required this.selectedGroupIndex,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 37,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        itemBuilder: (context, index) {
          final doc = groupDocs[index];
          final data = doc.data();
          final name = (data['displayNameSnapshot'] ?? 'Grupo').toString();
          final selected = index == selectedGroupIndex;
          return MontageSelectorChip(
            label: formatGroupDisplayName(name),
            selected: selected,
            onTap: () => onSelected(index),
          );
        },
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemCount: groupDocs.length,
      ),
    );
  }
}

class MontageSelectorChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const MontageSelectorChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(999);

    return Material(
      color: Colors.transparent,
      borderRadius: borderRadius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Ink(
          height: 25,
          padding: const EdgeInsets.symmetric(horizontal: 15),
          decoration: BoxDecoration(
            color: selected ? ssOrange : Colors.white,
            borderRadius: borderRadius,
            border: selected ? null : Border.all(color: ssBorder, width: 1.2),
          ),
          child: Center(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? Colors.white : ssText2,
                fontSize: 13,
                fontWeight: FontWeight.w800,
                height: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MontageWeekChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  const MontageWeekChip({
    super.key,
    required this.label,
    required this.selected,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        height: 25,
        padding: const EdgeInsets.symmetric(horizontal: 15),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? ssOrange : Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: selected ? null : Border.all(color: ssBorder, width: 1.2),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: selected ? Colors.white : ssText2,
            fontSize: 13,
            fontWeight: FontWeight.w800,
            height: 1,
          ),
        ),
      ),
    );
  }
}

enum MontageStyle { classic, polaroid, stickers }

extension MontageStyleMeta on MontageStyle {
  String get label => switch (this) {
    MontageStyle.classic => 'Clásico',
    MontageStyle.polaroid => 'Polaroid',
    MontageStyle.stickers => 'Stickers',
  };

  IconData get icon => switch (this) {
    MontageStyle.classic => Icons.dashboard_customize_rounded,
    MontageStyle.polaroid => Icons.photo_size_select_actual_rounded,
    MontageStyle.stickers => Icons.interests_rounded,
  };

  Color get accent => ssOrange;

  Color get softBackground => ssBg;
}

class MontageStyleSelector extends StatelessWidget {
  final MontageStyle selectedStyle;
  final ValueChanged<MontageStyle> onSelected;

  const MontageStyleSelector({
    super.key,
    required this.selectedStyle,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: MontageStyle.values.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final style = MontageStyle.values[index];
          final selected = style == selectedStyle;
          final accent = style.accent;

          return Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => onSelected(style),
              child: Ink(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 13),
                decoration: BoxDecoration(
                  color: selected
                      ? accent.withValues(alpha: 0.12)
                      : Colors.white,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: selected ? accent : ssBorder,
                    width: selected ? 1.6 : 1.1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      style.icon,
                      size: 17,
                      color: selected ? accent : ssText3,
                    ),
                    const SizedBox(width: 7),
                    Text(
                      style.label,
                      style: TextStyle(
                        color: selected ? ssText : ssText2,
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class MontagePoster extends StatefulWidget {
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> posts;
  final String groupName;
  final String weekKey;
  final int shuffleSeed;
  final MontageStyle style;
  final bool showEditingControls;

  const MontagePoster({
    super.key,
    required this.posts,
    required this.groupName,
    required this.weekKey,
    required this.shuffleSeed,
    required this.style,
    this.showEditingControls = true,
  });

  @override
  State<MontagePoster> createState() => _MontagePosterState();
}

class _MontageDragPayload {
  final String postId;
  final int fromIndex;

  const _MontageDragPayload({required this.postId, required this.fromIndex});
}

enum _MontageResizeEdge { top, bottom, left, right }

extension _MontageResizeEdgeDirection on _MontageResizeEdge {
  bool get isHorizontal =>
      this == _MontageResizeEdge.left || this == _MontageResizeEdge.right;
}

const double _montageTileGap = 8;
const double _classicFullWidthThreshold = 2 / 3;

class _MontagePosterState extends State<MontagePoster> {
  late List<QueryDocumentSnapshot<Map<String, dynamic>>> orderedPosts;
  final Map<String, double> customHeights = {};
  final Map<String, double> customWidthFractions = {};
  String? draggingPostId;
  String? resizingPostId;
  _MontageResizeEdge? activeResizeEdge;
  double resizeStartHeight = 0;
  double resizeStartWidthFraction = 0.5;

  @override
  void initState() {
    super.initState();
    _resetPosts();
  }

  @override
  void didUpdateWidget(covariant MontagePoster oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldIds = oldWidget.posts.map((doc) => doc.id).join('|');
    final newIds = widget.posts.map((doc) => doc.id).join('|');

    if (oldIds != newIds) {
      _resetPosts();
      return;
    }

    if (oldWidget.shuffleSeed != widget.shuffleSeed) {
      orderedPosts.shuffle(math.Random(widget.shuffleSeed));
    }
  }

  void _resetPosts() {
    orderedPosts = [...widget.posts];
    if (widget.shuffleSeed != 0) {
      orderedPosts.shuffle(math.Random(widget.shuffleSeed));
    }
  }

  double _heightFor(String postId, int index) {
    final baseHeights = [168.0, 198.0, 148.0, 182.0, 160.0, 190.0];
    return customHeights[postId] ?? baseHeights[index % baseHeights.length];
  }

  double _widthFractionFor(String postId) {
    return customWidthFractions[postId] ?? 0.5;
  }

  bool _hasCustomWidth(String postId) {
    return customWidthFractions.containsKey(postId);
  }

  bool _usesWideClassicRow(String postId) {
    return _widthFractionFor(postId) > _classicFullWidthThreshold;
  }

  double _normalizeWidthFraction(double value) {
    final clamped = value.clamp(0.5, 1.0).toDouble();
    return clamped <= 0.515 ? 0.5 : clamped;
  }

  void _movePostToIndex(_MontageDragPayload payload, int targetIndex) {
    final currentIndex = orderedPosts.indexWhere(
      (doc) => doc.id == payload.postId,
    );
    final sourceIndex = currentIndex >= 0 ? currentIndex : payload.fromIndex;
    if (sourceIndex < 0 || sourceIndex >= orderedPosts.length) return;

    final newIndex = targetIndex.clamp(0, orderedPosts.length - 1).toInt();
    if (newIndex == sourceIndex) return;

    setState(() {
      final item = orderedPosts.removeAt(sourceIndex);
      final insertIndex = newIndex.clamp(0, orderedPosts.length).toInt();
      orderedPosts.insert(insertIndex, item);
    });
  }

  void _startResize(String postId, _MontageResizeEdge edge) {
    final index = orderedPosts.indexWhere((doc) => doc.id == postId);
    HapticFeedback.selectionClick();
    setState(() {
      resizingPostId = postId;
      activeResizeEdge = edge;
      resizeStartHeight = _heightFor(postId, index < 0 ? 0 : index);
      resizeStartWidthFraction = _widthFractionFor(postId);
    });
  }

  void _updateResize(
    String postId,
    _MontageResizeEdge edge,
    Offset dragDelta,
    double resizeWidthBasis,
  ) {
    if (resizingPostId != postId || activeResizeEdge != edge) return;

    if (edge.isHorizontal) {
      final widthDelta = edge == _MontageResizeEdge.left
          ? -dragDelta.dx
          : dragDelta.dx;
      final nextWidthFraction = _normalizeWidthFraction(
        resizeStartWidthFraction + widthDelta / math.max(resizeWidthBasis, 1),
      );

      setState(() {
        if (nextWidthFraction == 0.5) {
          customWidthFractions.remove(postId);
        } else {
          customWidthFractions[postId] = nextWidthFraction;
        }
      });
      return;
    }

    final heightDelta = edge == _MontageResizeEdge.top
        ? -dragDelta.dy
        : dragDelta.dy;
    setState(() {
      customHeights[postId] = (resizeStartHeight + heightDelta)
          .clamp(120.0, 320.0)
          .toDouble();
    });
  }

  void _endResize() {
    if (resizingPostId == null) return;

    setState(() {
      resizingPostId = null;
      activeResizeEdge = null;
      resizeStartHeight = 0;
      resizeStartWidthFraction = 0.5;
    });
  }

  void _setDraggingPost(String? postId) {
    if (draggingPostId == postId) return;
    setState(() => draggingPostId = postId);
  }

  List<_MontageEntry> _buildEntries() {
    return [
      for (var i = 0; i < orderedPosts.length; i += 1)
        _MontageEntry(
          post: orderedPosts[i],
          index: i,
          height: _heightFor(orderedPosts[i].id, i),
        ),
    ];
  }

  Widget _buildColumn(List<_MontageEntry> entries) {
    return _MontageColumn(
      entries: entries,
      style: widget.style,
      draggingPostId: draggingPostId,
      resizingPostId: resizingPostId,
      activeResizeEdge: activeResizeEdge,
      showEditingControls: widget.showEditingControls,
      onDrop: _movePostToIndex,
      onDragStarted: (postId) => _setDraggingPost(postId),
      onDragEnded: () => _setDraggingPost(null),
      onResizeStart: _startResize,
      onResizeUpdate: _updateResize,
      onResizeEnd: _endResize,
    );
  }

  Widget _buildMasonryLayout(List<_MontageEntry> entries) {
    final left = <_MontageEntry>[];
    final right = <_MontageEntry>[];

    for (final entry in entries) {
      if (entry.index.isEven) {
        left.add(entry);
      } else {
        right.add(entry);
      }
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: _buildColumn(left)),
        const SizedBox(width: _montageTileGap),
        Expanded(child: _buildColumn(right)),
      ],
    );
  }

  Widget _buildClassicTile({
    required _MontageEntry entry,
    required double width,
    required double resizeWidthBasis,
  }) {
    return SizedBox(
      width: width,
      child: _MontageSelfieTile(
        post: entry.post,
        index: entry.index,
        height: entry.height,
        style: widget.style,
        isDragging: draggingPostId == entry.post.id,
        isResizing:
            widget.showEditingControls && resizingPostId == entry.post.id,
        activeResizeEdge:
            widget.showEditingControls && resizingPostId == entry.post.id
            ? activeResizeEdge
            : null,
        showEditingControls: widget.showEditingControls,
        allowHorizontalResize: true,
        horizontalResizeBasis: resizeWidthBasis,
        onDrop: _movePostToIndex,
        onDragStarted: (postId) => _setDraggingPost(postId),
        onDragEnded: () => _setDraggingPost(null),
        onResizeStart: _startResize,
        onResizeUpdate: _updateResize,
        onResizeEnd: _endResize,
      ),
    );
  }

  Widget _buildClassicWideRow(_MontageEntry entry, double maxWidth) {
    final fraction = _widthFractionFor(entry.post.id).clamp(0.5, 1.0);
    final alignment =
        resizingPostId == entry.post.id &&
            activeResizeEdge == _MontageResizeEdge.left
        ? Alignment.centerRight
        : Alignment.centerLeft;

    return Align(
      alignment: alignment,
      child: _buildClassicTile(
        entry: entry,
        width: maxWidth * fraction,
        resizeWidthBasis: maxWidth,
      ),
    );
  }

  Widget _buildClassicSingleRow(_MontageEntry entry, double maxWidth) {
    final fraction = _widthFractionFor(entry.post.id).clamp(0.5, 1.0);
    final width = maxWidth * fraction;

    return Align(
      alignment: Alignment.centerLeft,
      child: _buildClassicTile(
        entry: entry,
        width: width,
        resizeWidthBasis: maxWidth,
      ),
    );
  }

  Widget _buildClassicPairRow({
    required _MontageEntry leftEntry,
    required _MontageEntry rightEntry,
    required double maxWidth,
    required double leftFraction,
  }) {
    final pairWidth = math.max(0.0, maxWidth - _montageTileGap);
    final rightFraction = 1 - leftFraction;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildClassicTile(
          entry: leftEntry,
          width: pairWidth * leftFraction,
          resizeWidthBasis: pairWidth,
        ),
        const SizedBox(width: _montageTileGap),
        _buildClassicTile(
          entry: rightEntry,
          width: pairWidth * rightFraction,
          resizeWidthBasis: pairWidth,
        ),
      ],
    );
  }

  double _classicPairLeftFraction(
    _MontageEntry leftEntry,
    _MontageEntry rightEntry,
  ) {
    final leftCustom = _hasCustomWidth(leftEntry.post.id);
    final rightCustom = _hasCustomWidth(rightEntry.post.id);
    final leftFraction = _widthFractionFor(leftEntry.post.id);
    final rightFraction = _widthFractionFor(rightEntry.post.id);

    final resolved = switch ((leftCustom, rightCustom)) {
      (true, false) => leftFraction,
      (false, true) => 1 - rightFraction,
      (true, true) =>
        resizingPostId == rightEntry.post.id ? 1 - rightFraction : leftFraction,
      (false, false) => 0.5,
    };

    return resolved.clamp(
      1 - _classicFullWidthThreshold,
      _classicFullWidthThreshold,
    );
  }

  Widget _buildClassicLayout(List<_MontageEntry> entries) {
    if (entries.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final rows = <Widget>[];
        var index = 0;

        while (index < entries.length) {
          final entry = entries[index];

          if (_usesWideClassicRow(entry.post.id)) {
            rows.add(_buildClassicWideRow(entry, maxWidth));
            index += 1;
            continue;
          }

          if (index + 1 >= entries.length) {
            rows.add(_buildClassicSingleRow(entry, maxWidth));
            index += 1;
            continue;
          }

          final nextEntry = entries[index + 1];
          if (_usesWideClassicRow(nextEntry.post.id)) {
            rows.add(_buildClassicWideRow(nextEntry, maxWidth));
            rows.add(_buildClassicSingleRow(entry, maxWidth));
            index += 2;
            continue;
          }

          rows.add(
            _buildClassicPairRow(
              leftEntry: entry,
              rightEntry: nextEntry,
              maxWidth: maxWidth,
              leftFraction: _classicPairLeftFraction(entry, nextEntry),
            ),
          );
          index += 2;
        }

        return Column(children: rows);
      },
    );
  }

  Widget _buildPosterLayout(List<_MontageEntry> entries) {
    return switch (widget.style) {
      MontageStyle.classic => _buildClassicLayout(entries),
      MontageStyle.polaroid => _buildMasonryLayout(entries),
      MontageStyle.stickers => _StickerMontage(
        entries: entries,
        style: widget.style,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final entries = _buildEntries();
    final accent = widget.style.accent;

    return Container(
      padding: EdgeInsets.all(widget.style == MontageStyle.polaroid ? 16 : 14),
      decoration: BoxDecoration(
        color: widget.style.softBackground,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: accent.withValues(alpha: 0.18)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF78501E).withValues(alpha: 0.13),
            blurRadius: 34,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        children: [
          _MontagePosterHeader(
            groupName: widget.groupName,
            weekKey: widget.weekKey,
            style: widget.style,
          ),
          const SizedBox(height: 14),
          _buildPosterLayout(entries),
        ],
      ),
    );
  }
}

class _MontageEntry {
  final QueryDocumentSnapshot<Map<String, dynamic>> post;
  final int index;
  final double height;

  const _MontageEntry({
    required this.post,
    required this.index,
    required this.height,
  });
}

class _MontagePosterHeader extends StatelessWidget {
  final String groupName;
  final String weekKey;
  final MontageStyle style;

  const _MontagePosterHeader({
    required this.groupName,
    required this.weekKey,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    final accent = style.accent;

    return Column(
      children: [
        const SundayLogo(size: 30),
        const SizedBox(height: 10),
        Text(
          formatGroupDisplayName(groupName),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: ssTitle,
            fontSize: 20,
            height: 1.05,
            fontWeight: FontWeight.w900,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.center,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 260),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.76),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: accent.withValues(alpha: 0.22)),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF78501E).withValues(alpha: 0.06),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.calendar_month_rounded, color: accent, size: 14),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    weekBadgeText(weekKey),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: accent,
                      fontSize: 11,
                      height: 1,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 2),
        SizedBox(
          width: 46,
          height: 16,
          child: Center(
            child: Container(
              height: 2,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.24),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _StickerSelfieData {
  final _MontageEntry entry;
  final File file;

  const _StickerSelfieData({required this.entry, required this.file});
}

class _StickerCropData {
  final image_lib.Image image;
  final Rect faceBounds;

  const _StickerCropData({required this.image, required this.faceBounds});
}

const int _stickerOutputWidth = 540;
const int _stickerOutputHeight = 636;
const double _stickerAspect = _stickerOutputWidth / _stickerOutputHeight;
const double _stickerOutlineGrow = 6;

class _StickerMontage extends StatefulWidget {
  final List<_MontageEntry> entries;
  final MontageStyle style;

  const _StickerMontage({required this.entries, required this.style});

  @override
  State<_StickerMontage> createState() => _StickerMontageState();
}

class _StickerMontageState extends State<_StickerMontage> {
  late Future<List<_StickerSelfieData>> stickersFuture;
  late String entriesSignature;

  @override
  void initState() {
    super.initState();
    _configureFuture();
  }

  @override
  void didUpdateWidget(covariant _StickerMontage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextSignature = _signatureFor(widget.entries);
    if (nextSignature != entriesSignature) {
      _configureFuture();
    }
  }

  String _signatureFor(List<_MontageEntry> entries) {
    return entries.map((entry) => entry.post.id).join('|');
  }

  void _configureFuture() {
    entriesSignature = _signatureFor(widget.entries);
    stickersFuture = _loadStickerSelfies(widget.entries);
  }

  Future<List<_StickerSelfieData>> _loadStickerSelfies(
    List<_MontageEntry> entries,
  ) async {
    if (!LocalPhotoCache.instance.isSupported) return const [];

    final detector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.accurate,
        enableClassification: false,
        enableContours: false,
        enableLandmarks: true,
        enableTracking: false,
        minFaceSize: 0.06,
      ),
    );

    final stickers = <_StickerSelfieData>[];
    try {
      for (final entry in entries) {
        final data = entry.post.data();
        final imageUrl = (data['imageUrl'] ?? data['thumbUrl'] ?? '')
            .toString()
            .trim();
        if (imageUrl.isEmpty) continue;

        final file = await LocalPhotoCache.instance.getOrDownload(
          imageUrl,
          variant: 'sticker',
        );
        if (file == null) continue;

        try {
          final faces = await detector.processImage(
            InputImage.fromFilePath(file.path),
          );
          final stickerFile = await _createCutoutStickerFile(
            sourceFile: file,
            faces: faces,
            postId: entry.post.id,
          );
          if (stickerFile != null) {
            stickers.add(_StickerSelfieData(entry: entry, file: stickerFile));
          }
        } on PlatformException catch (error) {
          logDebug('No se pudo detectar caras para sticker: $error');
        } catch (error) {
          logDebug('No se pudo crear el recorte de sticker: $error');
        }
      }
    } on MissingPluginException catch (error) {
      logDebug('Detector de stickers no disponible: $error');
    } finally {
      await detector.close();
    }

    return stickers;
  }

  Future<File?> _createCutoutStickerFile({
    required File sourceFile,
    required List<Face> faces,
    required String postId,
  }) async {
    final bytes = await sourceFile.readAsBytes();
    final decoded = image_lib.decodeImage(bytes);
    if (decoded == null) return null;

    final image = image_lib.bakeOrientation(decoded);
    final face = _selectStickerFace(faces, image);
    final crop = _cropPersonSticker(
      image,
      face?.boundingBox ?? _fallbackFaceBounds(image),
    );
    final resized = image_lib.copyResize(
      crop.image,
      width: _stickerOutputWidth,
      height: _stickerOutputHeight,
      interpolation: image_lib.Interpolation.cubic,
    );
    final scaleX = _stickerOutputWidth / crop.image.width;
    final scaleY = _stickerOutputHeight / crop.image.height;
    final resizedFaceBounds = Rect.fromLTWH(
      crop.faceBounds.left * scaleX,
      crop.faceBounds.top * scaleY,
      crop.faceBounds.width * scaleX,
      crop.faceBounds.height * scaleY,
    );
    final sticker = _buildStickerCutout(resized, resizedFaceBounds);
    final safePostId = postId.replaceAll(RegExp(r'[^A-Za-z0-9_\-]+'), '_');
    final file = File(
      '${Directory.systemTemp.path}/sunday_sticker_${safePostId}_${sourceFile.lastModifiedSync().microsecondsSinceEpoch}.png',
    );
    await file.writeAsBytes(image_lib.encodePng(sticker), flush: true);
    return file;
  }

  Face? _selectStickerFace(List<Face> faces, image_lib.Image image) {
    if (faces.isEmpty) return null;

    final imageW = image.width.toDouble();
    final imageH = image.height.toDouble();
    final preferredCenter = Offset(imageW * 0.5, imageH * 0.36);
    Face? bestFace;
    var bestScore = -double.maxFinite;

    for (final face in faces) {
      final bounds = _clampRectToImage(face.boundingBox, imageW, imageH);
      if (bounds.width < 1 || bounds.height < 1) continue;

      final area = (bounds.width * bounds.height) / (imageW * imageH);
      final dx = (bounds.center.dx - preferredCenter.dx) / imageW;
      final dy = (bounds.center.dy - preferredCenter.dy) / imageH;
      final centered = 1 - math.sqrt(dx * dx + dy * dy).clamp(0.0, 1.0);
      final verticalBias = bounds.center.dy < imageH * 0.76 ? 0.22 : 0.0;
      final score =
          math.sqrt(area).clamp(0.0, 1.0).toDouble() * 3.2 +
          centered.toDouble() * 1.4 +
          verticalBias;

      if (score > bestScore) {
        bestScore = score;
        bestFace = face;
      }
    }

    return bestFace ?? faces.first;
  }

  Rect _fallbackFaceBounds(image_lib.Image image) {
    final imageW = image.width.toDouble();
    final imageH = image.height.toDouble();
    final faceH = math.min(imageH * 0.24, imageW * 0.38);
    final faceW = faceH * 0.78;

    return Rect.fromCenter(
      center: Offset(imageW * 0.5, imageH * 0.30),
      width: faceW,
      height: faceH,
    );
  }

  _StickerCropData _cropPersonSticker(
    image_lib.Image image,
    Rect rawFaceBounds,
  ) {
    final imageW = image.width.toDouble();
    final imageH = image.height.toDouble();
    final faceBounds = _clampRectToImage(rawFaceBounds, imageW, imageH);
    final faceW = math.max(faceBounds.width, imageW * 0.10);
    final faceH = math.max(faceBounds.height, imageH * 0.10);
    final faceCenterX = faceBounds.left + faceBounds.width / 2;

    var cropW = math.max(faceW * 3.18, imageW * 0.48);
    var cropH = cropW / _stickerAspect;
    final bodyCropH = faceH * 4.45;
    if (cropH < bodyCropH) {
      cropH = bodyCropH;
      cropW = cropH * _stickerAspect;
    }

    if (cropW > imageW || cropH > imageH) {
      final scale = math.min(imageW / cropW, imageH / cropH);
      cropW *= scale;
      cropH *= scale;
    }

    var cropX = faceCenterX - cropW / 2;
    var cropY = faceBounds.top - faceH * 0.88;
    final preferredBodyBottom = faceBounds.bottom + faceH * 3.28;
    if (cropY + cropH < preferredBodyBottom) {
      cropY = preferredBodyBottom - cropH;
    }

    cropX = cropX.clamp(0.0, math.max(0.0, imageW - cropW)).toDouble();
    cropY = cropY.clamp(0.0, math.max(0.0, imageH - cropH)).toDouble();

    final cropXInt = cropX.round().clamp(0, image.width - 1).toInt();
    final cropYInt = cropY.round().clamp(0, image.height - 1).toInt();
    final cropWidth = cropW.round().clamp(1, image.width - cropXInt).toInt();
    final cropHeight = cropH.round().clamp(1, image.height - cropYInt).toInt();
    final croppedFaceBounds = Rect.fromLTRB(
      (faceBounds.left - cropXInt).clamp(0.0, cropWidth.toDouble()).toDouble(),
      (faceBounds.top - cropYInt).clamp(0.0, cropHeight.toDouble()).toDouble(),
      (faceBounds.right - cropXInt).clamp(0.0, cropWidth.toDouble()).toDouble(),
      (faceBounds.bottom - cropYInt)
          .clamp(0.0, cropHeight.toDouble())
          .toDouble(),
    );

    return _StickerCropData(
      image: image_lib.copyCrop(
        image,
        x: cropXInt,
        y: cropYInt,
        width: cropWidth,
        height: cropHeight,
      ),
      faceBounds: croppedFaceBounds,
    );
  }

  Rect _clampRectToImage(Rect rect, double imageW, double imageH) {
    final safeImageW = math.max(imageW, 1.0);
    final safeImageH = math.max(imageH, 1.0);
    final left = rect.left.clamp(0.0, safeImageW - 1).toDouble();
    final top = rect.top.clamp(0.0, safeImageH - 1).toDouble();
    final right = rect.right.clamp(left + 1, safeImageW).toDouble();
    final bottom = rect.bottom.clamp(top + 1, safeImageH).toDouble();

    return Rect.fromLTRB(left, top, right, bottom);
  }

  image_lib.Image _buildStickerCutout(image_lib.Image source, Rect faceBounds) {
    final width = source.width;
    final height = source.height;
    final output = image_lib.Image(width: width, height: height, numChannels: 4)
      ..clear(image_lib.ColorRgba8(0, 0, 0, 0));

    for (var y = 0; y < height; y += 1) {
      for (var x = 0; x < width; x += 1) {
        final outerAlpha = _stickerSilhouetteAlpha(
          x: x.toDouble(),
          y: y.toDouble(),
          width: width.toDouble(),
          height: height.toDouble(),
          faceBounds: faceBounds,
          grow: _stickerOutlineGrow,
        );
        if (outerAlpha <= 0.01) continue;

        final innerAlpha = _stickerSilhouetteAlpha(
          x: x.toDouble(),
          y: y.toDouble(),
          width: width.toDouble(),
          height: height.toDouble(),
          faceBounds: faceBounds,
          grow: 0,
        ).clamp(0.0, 1.0).toDouble();
        final borderAlpha = (outerAlpha - innerAlpha).clamp(0.0, 1.0);
        final pixel = source.getPixel(x, y);
        final opacity = math
            .max(innerAlpha, borderAlpha * 0.72)
            .clamp(0.0, 1.0)
            .toDouble();
        final imageAmount = innerAlpha > 0.01
            ? 1.0
            : (1.0 - borderAlpha * 0.45).clamp(0.0, 1.0).toDouble();

        output.setPixelRgba(
          x,
          y,
          _blendStickerChannel(pixel.r, imageAmount),
          _blendStickerChannel(pixel.g, imageAmount),
          _blendStickerChannel(pixel.b, imageAmount),
          _alphaByte(opacity),
        );
      }
    }

    return output;
  }

  double _stickerSilhouetteAlpha({
    required double x,
    required double y,
    required double width,
    required double height,
    required Rect faceBounds,
    required double grow,
  }) {
    final faceW = math.max(faceBounds.width, width * 0.13);
    final faceH = math.max(faceBounds.height, height * 0.14);
    final faceCenterX = faceBounds.center.dx.clamp(width * 0.16, width * 0.84);
    final faceCenterY = faceBounds.center.dy;
    final feather = math.max(2.8, math.min(width, height) * 0.008);
    final shoulderHalfWidth = math.max(faceW * 1.48, width * 0.30);
    final torsoHalfWidth = math.max(faceW * 1.04, width * 0.23);
    final bodyTop = faceBounds.bottom - faceH * 0.02;
    final bodyBottom = math.min(height - 8, faceBounds.bottom + faceH * 3.16);

    var alpha = 0.0;
    alpha = math.max(
      alpha,
      _ellipseAlpha(
        x,
        y,
        faceCenterX,
        faceCenterY - faceH * 0.04,
        faceW * 0.64 + grow,
        faceH * 0.72 + grow,
        feather,
      ),
    );
    alpha = math.max(
      alpha,
      _ellipseAlpha(
        x,
        y,
        faceCenterX,
        faceBounds.bottom + faceH * 0.18,
        faceW * 0.29 + grow * 0.54,
        faceH * 0.38 + grow,
        feather,
      ),
    );
    alpha = math.max(
      alpha,
      _ellipseAlpha(
        x,
        y,
        faceCenterX,
        faceBounds.bottom + faceH * 0.78,
        shoulderHalfWidth + grow,
        faceH * 0.66 + grow,
        feather,
      ),
    );
    alpha = math.max(
      alpha,
      _taperedBodyAlpha(
        x: x,
        y: y,
        centerX: faceCenterX,
        top: bodyTop,
        bottom: bodyBottom,
        topHalfWidth: faceW * 0.46,
        shoulderHalfWidth: shoulderHalfWidth,
        bottomHalfWidth: torsoHalfWidth,
        grow: grow,
        feather: feather,
      ),
    );
    alpha = math.max(
      alpha,
      _ellipseAlpha(
        x,
        y,
        faceCenterX,
        faceBounds.bottom + faceH * 2.34,
        torsoHalfWidth + grow,
        faceH * 1.18 + grow,
        feather,
      ),
    );

    return alpha.clamp(0.0, 1.0).toDouble();
  }

  double _ellipseAlpha(
    double x,
    double y,
    double centerX,
    double centerY,
    double radiusX,
    double radiusY,
    double feather,
  ) {
    final safeRadiusX = math.max(radiusX, 1.0);
    final safeRadiusY = math.max(radiusY, 1.0);
    final dx = (x - centerX) / safeRadiusX;
    final dy = (y - centerY) / safeRadiusY;
    final normalizedDistance = math.sqrt(dx * dx + dy * dy);
    final edgeDistance =
        (1 - normalizedDistance) * math.min(safeRadiusX, safeRadiusY);

    return _smoothStep(0, feather, edgeDistance);
  }

  double _taperedBodyAlpha({
    required double x,
    required double y,
    required double centerX,
    required double top,
    required double bottom,
    required double topHalfWidth,
    required double shoulderHalfWidth,
    required double bottomHalfWidth,
    required double grow,
    required double feather,
  }) {
    if (bottom <= top) return 0;

    final expandedTop = top - grow;
    final expandedBottom = bottom + grow;
    final verticalEdge = math.min(y - expandedTop, expandedBottom - y);
    final t = ((y - top) / (bottom - top)).clamp(0.0, 1.0).toDouble();
    final shoulderEase = _smoothStep(0, 0.34, t);
    final lowerEase = _smoothStep(0.34, 1, t);
    final upperWidth = _lerp(topHalfWidth, shoulderHalfWidth, shoulderEase);
    final halfWidth = _lerp(upperWidth, bottomHalfWidth, lowerEase) + grow;
    final horizontalEdge = halfWidth - (x - centerX).abs();

    return math
        .min(
          _smoothStep(0, feather, horizontalEdge),
          _smoothStep(0, feather, verticalEdge),
        )
        .clamp(0.0, 1.0)
        .toDouble();
  }

  double _smoothStep(double edge0, double edge1, double value) {
    if (value <= edge0) return 0;
    if (value >= edge1) return 1;

    final t = ((value - edge0) / (edge1 - edge0)).clamp(0.0, 1.0).toDouble();
    return t * t * (3 - 2 * t);
  }

  double _lerp(double start, double end, double amount) {
    return start + (end - start) * amount;
  }

  int _blendStickerChannel(num channel, double imageAmount) {
    final amount = imageAmount.clamp(0.0, 1.0).toDouble();
    final blended = channel.toDouble() * amount + 255 * (1 - amount);
    return blended.round().clamp(0, 255).toInt();
  }

  int _alphaByte(double alpha) {
    return (alpha.clamp(0.0, 1.0) * 255).round().clamp(0, 255).toInt();
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.style.accent;

    return FutureBuilder<List<_StickerSelfieData>>(
      future: stickersFuture,
      builder: (context, snapshot) {
        final waiting = snapshot.connectionState != ConnectionState.done;
        final stickers = snapshot.data ?? const <_StickerSelfieData>[];

        if (waiting) {
          return SizedBox(
            height: 244,
            child: Center(
              child: CircularProgressIndicator(color: accent, strokeWidth: 2.4),
            ),
          );
        }

        if (stickers.isEmpty) {
          return Container(
            height: 220,
            alignment: Alignment.center,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: accent.withValues(alpha: 0.16)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.face_retouching_off_rounded,
                  color: accent,
                  size: 34,
                ),
                const SizedBox(height: 10),
                const Text(
                  'No hay selfies individuales para este estilo',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: ssText2,
                    fontSize: 13,
                    height: 1.3,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          );
        }

        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final columns = width < 280 || stickers.length == 1 ? 1 : 2;
            final size = columns == 1 ? 196.0 : math.min(150.0, width * 0.45);
            final stickerHeight = size * 1.18;
            final rowStride = size * 0.82;
            final rows = (stickers.length / columns).ceil();
            final height = columns == 1
                ? stickerHeight + 42.0
                : stickerHeight + math.max(0, rows - 1) * rowStride + 48.0;

            return SizedBox(
              height: height,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.38),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: accent.withValues(alpha: 0.10),
                        ),
                      ),
                    ),
                  ),
                  for (var i = 0; i < stickers.length; i += 1)
                    _PositionedStickerSelfie(
                      sticker: stickers[i],
                      index: i,
                      columns: columns,
                      size: size,
                      width: width,
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _PositionedStickerSelfie extends StatelessWidget {
  final _StickerSelfieData sticker;
  final int index;
  final int columns;
  final double size;
  final double width;

  const _PositionedStickerSelfie({
    required this.sticker,
    required this.index,
    required this.columns,
    required this.size,
    required this.width,
  });

  @override
  Widget build(BuildContext context) {
    final row = index ~/ columns;
    final col = index % columns;
    final singleColumn = columns == 1;
    final stickerHeight = size * 1.18;
    final rowStride = size * 0.82;
    final left = singleColumn
        ? (width - size) / 2
        : col == 0
        ? 12.0
        : width - size - 12.0;
    final top = singleColumn
        ? 18.0
        : 18.0 + row * rowStride + (col.isOdd ? size * 0.18 : 0.0);
    final rotation = const [-0.12, 0.09, -0.06, 0.11, -0.09, 0.07][index % 6];

    return Positioned(
      left: left,
      top: top,
      child: Transform.rotate(
        angle: rotation,
        child: SizedBox(
          width: size,
          height: stickerHeight,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 16,
                right: 16,
                bottom: 12,
                child: Container(
                  height: 24,
                  decoration: BoxDecoration(
                    color: const Color(0xFF593449).withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(999),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF593449).withValues(alpha: 0.18),
                        blurRadius: 18,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned.fill(
                child: Image.file(
                  sticker.file,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const _ImageErrorFill(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MontageColumn extends StatelessWidget {
  final List<_MontageEntry> entries;
  final MontageStyle style;
  final String? draggingPostId;
  final String? resizingPostId;
  final _MontageResizeEdge? activeResizeEdge;
  final bool showEditingControls;
  final void Function(_MontageDragPayload payload, int targetIndex) onDrop;
  final ValueChanged<String> onDragStarted;
  final VoidCallback onDragEnded;
  final void Function(String postId, _MontageResizeEdge edge) onResizeStart;
  final void Function(
    String postId,
    _MontageResizeEdge edge,
    Offset dragDelta,
    double resizeWidthBasis,
  )
  onResizeUpdate;
  final VoidCallback onResizeEnd;

  const _MontageColumn({
    required this.entries,
    required this.style,
    required this.draggingPostId,
    required this.resizingPostId,
    required this.activeResizeEdge,
    required this.showEditingControls,
    required this.onDrop,
    required this.onDragStarted,
    required this.onDragEnded,
    required this.onResizeStart,
    required this.onResizeUpdate,
    required this.onResizeEnd,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: entries.map((entry) {
        return _MontageSelfieTile(
          post: entry.post,
          index: entry.index,
          height: entry.height,
          style: style,
          isDragging: draggingPostId == entry.post.id,
          isResizing: showEditingControls && resizingPostId == entry.post.id,
          activeResizeEdge:
              showEditingControls && resizingPostId == entry.post.id
              ? activeResizeEdge
              : null,
          showEditingControls: showEditingControls,
          allowHorizontalResize: false,
          horizontalResizeBasis: 0,
          onDrop: onDrop,
          onDragStarted: onDragStarted,
          onDragEnded: onDragEnded,
          onResizeStart: onResizeStart,
          onResizeUpdate: onResizeUpdate,
          onResizeEnd: onResizeEnd,
        );
      }).toList(),
    );
  }
}

class _MontageSelfieTile extends StatelessWidget {
  final QueryDocumentSnapshot<Map<String, dynamic>> post;
  final int index;
  final double height;
  final MontageStyle style;
  final bool isDragging;
  final bool isResizing;
  final _MontageResizeEdge? activeResizeEdge;
  final bool showEditingControls;
  final void Function(_MontageDragPayload payload, int targetIndex) onDrop;
  final ValueChanged<String> onDragStarted;
  final VoidCallback onDragEnded;
  final void Function(String postId, _MontageResizeEdge edge) onResizeStart;
  final void Function(
    String postId,
    _MontageResizeEdge edge,
    Offset dragDelta,
    double resizeWidthBasis,
  )
  onResizeUpdate;
  final VoidCallback onResizeEnd;
  final bool allowHorizontalResize;
  final double horizontalResizeBasis;

  const _MontageSelfieTile({
    required this.post,
    required this.index,
    required this.height,
    required this.style,
    required this.isDragging,
    required this.isResizing,
    required this.activeResizeEdge,
    required this.showEditingControls,
    required this.allowHorizontalResize,
    required this.horizontalResizeBasis,
    required this.onDrop,
    required this.onDragStarted,
    required this.onDragEnded,
    required this.onResizeStart,
    required this.onResizeUpdate,
    required this.onResizeEnd,
  });

  Widget _buildPhoto({
    required bool highlighted,
    required bool lifted,
    required bool showReactions,
  }) {
    final data = post.data();
    final imageUrl = (data['thumbUrl'] ?? data['imageUrl'] ?? '').toString();
    final isPolaroid = style == MontageStyle.polaroid;
    final accent = style.accent;
    final photoRadius = isPolaroid ? 6.0 : 14.0;
    final outerRadius = isPolaroid ? 8.0 : 14.0;
    final rotation = isPolaroid
        ? const [-0.025, 0.018, -0.012, 0.024, -0.018, 0.014][index % 6]
        : 0.0;
    final polaroidBottomPadding = showReactions ? 31.0 : 24.0;

    Widget reactionsStrip({required bool overlay, required bool plain}) {
      return GroupAggregatedReactionsStrip(
        reactionsRef: post.reference
            .collection('reactions')
            .orderBy('updatedAt', descending: true),
        compact: true,
        overlay: overlay,
        plain: plain,
        hideWhenEmpty: true,
      );
    }

    final imageStack = ClipRRect(
      borderRadius: BorderRadius.circular(photoRadius),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (imageUrl.isNotEmpty)
            CachedRemoteImage(
              imageUrl: imageUrl,
              cacheVariant: 'thumbnail',
              fit: BoxFit.cover,
              loadingWidget: const _ImageLoadingFill(),
              errorWidget: const _ImageErrorFill(),
            )
          else
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [accent, ssOrangeMid],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
            ),
          const _PhotoGradientOverlay(),
          if (highlighted)
            DecoratedBox(
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(photoRadius),
              ),
            ),
          if (showReactions && !isPolaroid)
            Positioned(
              left: 7,
              right: 7,
              bottom: 7,
              child: reactionsStrip(overlay: true, plain: false),
            ),
        ],
      ),
    );
    final photoContent = isPolaroid && showReactions
        ? Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(child: imageStack),
              Positioned(
                left: 4,
                right: 4,
                bottom: -polaroidBottomPadding + 2,
                child: reactionsStrip(overlay: false, plain: true),
              ),
            ],
          )
        : imageStack;

    return Transform.rotate(
      angle: lifted ? 0 : rotation,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        height: height + (isPolaroid ? 7 + polaroidBottomPadding : 0),
        margin: EdgeInsets.fromLTRB(
          isPolaroid ? 3 : 0,
          isPolaroid ? 3 : 0,
          isPolaroid ? 3 : 0,
          isPolaroid ? 13 : 7,
        ),
        padding: isPolaroid
            ? EdgeInsets.fromLTRB(7, 7, 7, polaroidBottomPadding)
            : EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: isPolaroid ? Colors.white : ssOrangeLight,
          borderRadius: BorderRadius.circular(outerRadius),
          border: Border.all(
            color: highlighted || isResizing
                ? accent
                : isPolaroid
                ? const Color(0xFFF2ECE4)
                : Colors.white.withValues(alpha: 0),
            width: highlighted || isResizing
                ? 2
                : isPolaroid
                ? 1
                : 0,
          ),
          boxShadow: [
            if (isPolaroid)
              BoxShadow(
                color: const Color(0xFF6B4A2E).withValues(alpha: 0.09),
                blurRadius: isPolaroid ? 18 : 14,
                offset: const Offset(0, 7),
              ),
            if (lifted || highlighted)
              BoxShadow(
                color: Colors.black.withValues(alpha: lifted ? 0.28 : 0.14),
                blurRadius: lifted ? 24 : 14,
                offset: Offset(0, lifted ? 10 : 4),
              ),
          ],
        ),
        child: photoContent,
      ),
    );
  }

  Widget _buildResizeHandle(_MontageResizeEdge edge, double resizeWidthBasis) {
    final active = activeResizeEdge == edge;
    final horizontal = edge.isHorizontal;
    final alignedTop = edge == _MontageResizeEdge.top;
    final alignedLeft = edge == _MontageResizeEdge.left;

    if (horizontal) {
      return Positioned(
        left: alignedLeft ? 0 : null,
        right: alignedLeft ? null : 0,
        top: 12,
        bottom: 19,
        width: 34,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onLongPressStart: (_) => onResizeStart(post.id, edge),
          onLongPressMoveUpdate: (details) => onResizeUpdate(
            post.id,
            edge,
            details.offsetFromOrigin,
            resizeWidthBasis,
          ),
          onLongPressEnd: (_) => onResizeEnd(),
          onLongPressCancel: onResizeEnd,
          child: Align(
            alignment: alignedLeft
                ? Alignment.centerLeft
                : Alignment.centerRight,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 130),
              width: active ? 5 : 4,
              height: active ? 58 : 42,
              margin: EdgeInsets.only(left: alignedLeft ? 7 : 0, right: 7),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: active ? 0.46 : 0.22),
                borderRadius: BorderRadius.circular(999),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: active ? 0.10 : 0.04),
                    blurRadius: active ? 8 : 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Positioned(
      left: 0,
      right: 0,
      top: alignedTop ? 0 : null,
      bottom: alignedTop ? null : 7,
      height: 34,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPressStart: (_) => onResizeStart(post.id, edge),
        onLongPressMoveUpdate: (details) => onResizeUpdate(
          post.id,
          edge,
          details.offsetFromOrigin,
          resizeWidthBasis,
        ),
        onLongPressEnd: (_) => onResizeEnd(),
        onLongPressCancel: onResizeEnd,
        child: Align(
          alignment: alignedTop ? Alignment.topCenter : Alignment.bottomCenter,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 130),
            width: active ? 58 : 42,
            height: active ? 5 : 4,
            margin: EdgeInsets.only(top: alignedTop ? 7 : 0, bottom: 7),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: active ? 0.46 : 0.22),
              borderRadius: BorderRadius.circular(999),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: active ? 0.10 : 0.04),
                  blurRadius: active ? 8 : 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInteractiveTile({
    required bool highlighted,
    required bool dimmed,
    required double resizeWidthBasis,
  }) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 120),
      opacity: dimmed ? 0.34 : 1,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          _buildPhoto(
            highlighted: highlighted,
            lifted: false,
            showReactions: true,
          ),
          if (showEditingControls) ...[
            _buildResizeHandle(_MontageResizeEdge.top, resizeWidthBasis),
            _buildResizeHandle(_MontageResizeEdge.bottom, resizeWidthBasis),
            if (allowHorizontalResize) ...[
              _buildResizeHandle(_MontageResizeEdge.left, resizeWidthBasis),
              _buildResizeHandle(_MontageResizeEdge.right, resizeWidthBasis),
            ],
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DragTarget<_MontageDragPayload>(
      onWillAcceptWithDetails: (details) => details.data.postId != post.id,
      onAcceptWithDetails: (details) => onDrop(details.data, index),
      builder: (context, candidateData, rejectedData) {
        final highlighted = candidateData.isNotEmpty;

        return LayoutBuilder(
          builder: (context, constraints) {
            final resizeWidthBasis = allowHorizontalResize
                ? horizontalResizeBasis
                : constraints.maxWidth;

            return LongPressDraggable<_MontageDragPayload>(
              data: _MontageDragPayload(postId: post.id, fromIndex: index),
              delay: const Duration(seconds: 1),
              rootOverlay: true,
              maxSimultaneousDrags: isResizing || !showEditingControls ? 0 : 1,
              onDragStarted: () => onDragStarted(post.id),
              onDragEnd: (_) => onDragEnded(),
              feedback: SizedBox(
                width: constraints.maxWidth,
                child: Transform.scale(
                  scale: 1.03,
                  child: Material(
                    type: MaterialType.transparency,
                    child: _buildPhoto(
                      highlighted: true,
                      lifted: true,
                      showReactions: false,
                    ),
                  ),
                ),
              ),
              childWhenDragging: _buildInteractiveTile(
                highlighted: highlighted,
                dimmed: true,
                resizeWidthBasis: resizeWidthBasis,
              ),
              child: _buildInteractiveTile(
                highlighted: highlighted,
                dimmed: isDragging,
                resizeWidthBasis: resizeWidthBasis,
              ),
            );
          },
        );
      },
    );
  }
}

class ProfileScreen extends StatefulWidget {
  final User user;

  const ProfileScreen({super.key, required this.user});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  @override
  Widget build(BuildContext context) {
    SundayClockScope.watch(context);
    final userRef = FirebaseFirestore.instance
        .collection('users')
        .doc(widget.user.uid);
    final userGroupsRef = FirebaseFirestore.instance
        .collection('users')
        .doc(widget.user.uid)
        .collection('groups')
        .orderBy('joinedAt', descending: true);

    return Scaffold(
      backgroundColor: ssBg,
      body: SafeArea(
        child: Column(
          children: [
            const AppHeader(),
            Expanded(
              child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                stream: userRef.snapshots(),
                builder: (context, userSnapshot) {
                  final userData = userSnapshot.data?.data();
                  final rawBaseName = userData?['baseName']?.toString().trim();
                  final authDisplayName = widget.user.displayName?.trim();
                  final baseName = formatUserDisplayName(
                    rawBaseName != null && rawBaseName.isNotEmpty
                        ? rawBaseName
                        : authDisplayName != null && authDisplayName.isNotEmpty
                        ? authDisplayName
                        : 'Usuario',
                  );
                  final basePhotoUrl = userData?['basePhotoUrl'] as String?;
                  final createdAt = timestampToDate(userData?['createdAt']);
                  final memberSince = createdAt == null
                      ? 'Miembro desde ahora'
                      : 'Miembro desde ${monthName(createdAt.month)} ${createdAt.year}';
                  final screenHeight = MediaQuery.sizeOf(context).height;
                  final compactProfile = screenHeight < 780;
                  final profileAvatarSize = compactProfile ? 86.0 : 99.0;
                  final profileTopPadding = compactProfile ? 6.0 : 16.0;
                  final profileBottomPadding = compactProfile ? 14.0 : 24.0;
                  final profileMainGap = compactProfile ? 12.0 : 20.0;
                  final profileMenuGap = compactProfile ? 10.0 : 16.0;
                  void openEditProfile() {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => EditProfileScreen(user: widget.user),
                      ),
                    );
                  }

                  return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: userGroupsRef.snapshots(),
                    builder: (context, groupsSnapshot) {
                      final groupDocs = groupsSnapshot.data?.docs ?? [];
                      final groupsCount = groupDocs.length;

                      return FutureBuilder<int>(
                        future: countUserSelfies(widget.user.uid, groupDocs),
                        builder: (context, selfiesSnapshot) {
                          final selfiesCount = selfiesSnapshot.data ?? 0;

                          return ListView(
                            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                            children: [
                              Padding(
                                padding: EdgeInsets.fromLTRB(
                                  0,
                                  profileTopPadding,
                                  0,
                                  profileBottomPadding,
                                ),
                                child: Column(
                                  children: [
                                    ProfileAvatar(
                                      name: baseName,
                                      photoUrl: basePhotoUrl,
                                      size: profileAvatarSize,
                                      onTap: openEditProfile,
                                    ),
                                    SizedBox(height: compactProfile ? 12 : 16),
                                    Text(
                                      baseName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        color: ssText,
                                        fontSize: 22,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      memberSince,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        color: ssText3,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              ProfileStatsBar(
                                groupsCount: groupsCount,
                                activeWeeks: activeWeeksFromGroups(groupDocs),
                                selfiesCount: selfiesCount,
                              ),
                              SizedBox(height: profileMainGap),
                              ProfileSelfiesShortcut(
                                selfiesCount: selfiesCount,
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          MySelfiesScreen(user: widget.user),
                                    ),
                                  );
                                },
                              ),
                              SizedBox(height: profileMenuGap),
                              ProfileMenuRow(
                                icon: ProfileLineIconKind.notifications,
                                label: 'Notificaciones',
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          NotificationsSettingsScreen(
                                            user: widget.user,
                                          ),
                                    ),
                                  );
                                },
                              ),
                              ProfileMenuRow(
                                icon: ProfileLineIconKind.editProfile,
                                label: 'Editar perfil',
                                onTap: openEditProfile,
                              ),
                              ProfileMenuRow(
                                icon: ProfileLineIconKind.suggestions,
                                label: 'Sugerencias',
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => SuggestionsScreen(
                                        user: widget.user,
                                        authorName: baseName,
                                      ),
                                    ),
                                  );
                                },
                              ),
                              ProfileMenuRow(
                                icon: ProfileLineIconKind.settings,
                                label: 'Ajustes',
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          AppSettingsScreen(user: widget.user),
                                    ),
                                  );
                                },
                              ),
                            ],
                          );
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class EditProfileScreen extends StatefulWidget {
  final User user;

  const EditProfileScreen({super.key, required this.user});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final TextEditingController nameController = TextEditingController();
  bool saving = false;
  bool saved = false;
  bool nameInitialized = false;
  XFile? selectedPhoto;

  @override
  void dispose() {
    nameController.dispose();
    super.dispose();
  }

  Future<void> _choosePhotoSource() async {
    if (!esDomingo()) {
      showSundaySnack(
        context,
        'La foto de perfil solo se puede cambiar los domingos',
      );
      return;
    }

    final source = await showModalBottomSheet<image_picker.ImageSource>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => const ProfilePhotoSourceSheet(),
    );

    if (!mounted || source == null) return;

    if (source == image_picker.ImageSource.camera) {
      final photo = await Navigator.push<XFile>(
        context,
        MaterialPageRoute(
          builder: (_) =>
              const CameraCaptureScreen(groupName: 'Foto de perfil'),
        ),
      );

      if (!mounted || photo == null) return;
      final validPhoto = await validarFotoSelfieParaSubida(context, photo);
      if (!mounted || !validPhoto) return;

      setState(() {
        selectedPhoto = photo;
        saved = false;
      });
      return;
    }

    try {
      final picker = image_picker.ImagePicker();
      final photo = await picker.pickImage(
        source: image_picker.ImageSource.gallery,
        imageQuality: 88,
        maxWidth: 1600,
      );

      if (!mounted || photo == null) return;
      final validPhoto = await validarFotoSelfieParaSubida(context, photo);
      if (!mounted || !validPhoto) return;

      setState(() {
        selectedPhoto = photo;
        saved = false;
      });
    } catch (error) {
      if (!mounted) return;
      showSundaySnack(context, 'No se pudo abrir la galería: $error');
    }
  }

  Future<void> _saveProfile({
    required String currentName,
    required String? currentPhotoStoragePath,
  }) async {
    final newName = nameController.text.trim();
    final photo = selectedPhoto;
    final nameChanged = newName.isNotEmpty && newName != currentName;
    final photoChanged = photo != null;

    if (newName.isEmpty) {
      showSundaySnack(context, 'El nombre no puede estar vacío');
      return;
    }

    if (!nameChanged && !photoChanged) return;

    if (photoChanged && !esDomingo()) {
      showSundaySnack(
        context,
        'La foto de perfil solo se puede cambiar los domingos',
      );
      return;
    }

    if (photoChanged) {
      final validPhoto = await validarFotoSelfieParaSubida(context, photo);
      if (!mounted || !validPhoto) return;
    }

    if (saving) return;

    setState(() => saving = true);

    try {
      if (nameChanged) {
        await actualizarNombreUsuario(widget.user, newName);
      }

      if (photoChanged) {
        await actualizarFotoPerfilUsuario(
          user: widget.user,
          foto: photo,
          previousStoragePath: currentPhotoStoragePath,
        );
      }

      if (!mounted) return;
      FocusScope.of(context).unfocus();
      setState(() {
        selectedPhoto = null;
        saved = true;
        nameInitialized = false;
      });
      showSundaySnack(context, 'Perfil actualizado');
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (mounted) Navigator.pop(context);
    } on SelfiePhotoValidationException catch (error) {
      if (!mounted) return;
      showSundaySnack(context, error.message);
    } catch (error) {
      if (!mounted) return;
      showSundaySnack(context, 'Error: $error');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    SundayClockScope.watch(context);
    final userRef = FirebaseFirestore.instance
        .collection('users')
        .doc(widget.user.uid);

    return Scaffold(
      backgroundColor: ssBg,
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(onBack: () => Navigator.pop(context)),
            Expanded(
              child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                stream: userRef.snapshots(),
                builder: (context, snapshot) {
                  final data = snapshot.data?.data();

                  if (snapshot.connectionState == ConnectionState.waiting &&
                      data == null) {
                    return const Center(
                      child: CircularProgressIndicator(color: ssOrange),
                    );
                  }

                  final rawBaseName = data?['baseName']?.toString().trim();
                  final authDisplayName = widget.user.displayName?.trim();
                  final baseName = formatUserDisplayName(
                    rawBaseName != null && rawBaseName.isNotEmpty
                        ? rawBaseName
                        : authDisplayName != null && authDisplayName.isNotEmpty
                        ? authDisplayName
                        : 'Usuario',
                  );
                  final basePhotoUrl = data?['basePhotoUrl'] as String?;
                  final profilePhotoStoragePath =
                      data?['profilePhotoStoragePath']?.toString();

                  if (!nameInitialized &&
                      (data != null || baseName != 'Usuario')) {
                    nameController.text = baseName;
                    nameController.selection = TextSelection.fromPosition(
                      TextPosition(offset: nameController.text.length),
                    );
                    nameInitialized = true;
                  }

                  return ValueListenableBuilder<TextEditingValue>(
                    valueListenable: nameController,
                    builder: (context, value, _) {
                      final newName = value.text.trim();
                      final nameChanged =
                          newName.isNotEmpty && newName != baseName;
                      final photoChanged = selectedPhoto != null;
                      final hasChanges = nameChanged || photoChanged;
                      final canSave =
                          hasChanges && !saving && newName.isNotEmpty;

                      return ListView(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                        children: [
                          const Text(
                            'Editar perfil',
                            style: TextStyle(
                              color: ssTitle,
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(0, 4, 0, 20),
                            child: Column(
                              children: [
                                EditableProfileAvatar(
                                  name: newName.isEmpty ? baseName : newName,
                                  photoUrl: basePhotoUrl,
                                  selectedPhoto: selectedPhoto,
                                  canChangePhoto: esDomingo(),
                                  onTap: saving ? null : _choosePhotoSource,
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  esDomingo()
                                      ? 'Hoy puedes cambiar tu foto de perfil'
                                      : 'La foto de perfil se puede cambiar cada domingo',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: ssText3,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 24),
                          const Text(
                            'NOMBRE',
                            style: TextStyle(
                              color: ssText3,
                              fontSize: 12,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(height: 8),
                          SundayInput(
                            controller: nameController,
                            hintText: 'Tu nombre',
                          ),
                          const SizedBox(height: 6),
                          const Padding(
                            padding: EdgeInsets.only(left: 4),
                            child: Text(
                              'Este es tu nombre en Sunday Selfie',
                              style: TextStyle(
                                color: ssText3,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),
                          SundayButton(
                            text: saved
                                ? 'Guardado'
                                : saving
                                ? 'Guardando...'
                                : 'Guardar cambios',
                            variant: saved
                                ? SundayButtonVariant.secondary
                                : SundayButtonVariant.primary,
                            onPressed: canSave
                                ? () => _saveProfile(
                                    currentName: baseName,
                                    currentPhotoStoragePath:
                                        profilePhotoStoragePath,
                                  )
                                : null,
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SuggestionsScreen extends StatefulWidget {
  final User user;
  final String authorName;

  const SuggestionsScreen({
    super.key,
    required this.user,
    required this.authorName,
  });

  @override
  State<SuggestionsScreen> createState() => _SuggestionsScreenState();
}

class _SuggestionsScreenState extends State<SuggestionsScreen> {
  final TextEditingController suggestionController = TextEditingController();
  bool sending = false;
  bool sent = false;

  @override
  void dispose() {
    suggestionController.dispose();
    super.dispose();
  }

  Future<void> _sendSuggestion() async {
    final text = suggestionController.text.trim();

    if (text.length < 5) {
      showSundaySnack(context, 'Escribe un poco más para enviar la sugerencia');
      return;
    }

    if (text.length > 1000) {
      showSundaySnack(
        context,
        'La sugerencia no puede superar 1000 caracteres',
      );
      return;
    }

    if (sending) return;

    setState(() => sending = true);

    try {
      await enviarSugerenciaUsuario(
        user: widget.user,
        authorName: widget.authorName,
        text: text,
      );

      if (!mounted) return;
      FocusScope.of(context).unfocus();
      suggestionController.clear();
      setState(() => sent = true);
      showSundaySnack(context, 'Sugerencia enviada. ¡Gracias!');
    } catch (error) {
      if (!mounted) return;
      showSundaySnack(context, 'Error enviando sugerencia: $error');
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ssBg,
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(onBack: () => Navigator.pop(context)),
            Expanded(
              child: ValueListenableBuilder<TextEditingValue>(
                valueListenable: suggestionController,
                builder: (context, value, _) {
                  final suggestion = value.text.trim();
                  final canSend =
                      suggestion.length >= 5 &&
                      suggestion.length <= 1000 &&
                      !sending;

                  return ListView(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                    children: [
                      const Text(
                        'Sugerencias',
                        style: TextStyle(
                          color: ssTitle,
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 16),
                      SundayCard(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                        child: TextField(
                          controller: suggestionController,
                          enabled: !sending,
                          minLines: 7,
                          maxLines: 10,
                          maxLength: 1000,
                          keyboardType: TextInputType.multiline,
                          textCapitalization: TextCapitalization.sentences,
                          cursorColor: ssOrange,
                          onChanged: (_) {
                            if (sent) setState(() => sent = false);
                          },
                          style: const TextStyle(
                            color: ssText,
                            fontSize: 15.5,
                            fontWeight: FontWeight.w600,
                            height: 1.35,
                          ),
                          decoration: InputDecoration(
                            hintText: 'Cuéntanos qué mejorarías',
                            hintStyle: const TextStyle(
                              color: ssText3,
                              fontWeight: FontWeight.w500,
                            ),
                            filled: true,
                            fillColor: ssBg,
                            counterStyle: const TextStyle(color: ssText3),
                            contentPadding: const EdgeInsets.all(14),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: const BorderSide(
                                color: ssBorder,
                                width: 1.5,
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: const BorderSide(
                                color: ssOrange,
                                width: 1.5,
                              ),
                            ),
                            disabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: const BorderSide(
                                color: ssBorder,
                                width: 1.5,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      SundayButton(
                        text: sent
                            ? 'Sugerencia enviada'
                            : sending
                            ? 'Enviando...'
                            : 'Enviar sugerencia',
                        variant: sent
                            ? SundayButtonVariant.secondary
                            : SundayButtonVariant.primary,
                        onPressed: canSend ? _sendSuggestion : null,
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class EditableProfileAvatar extends StatelessWidget {
  final String name;
  final String? photoUrl;
  final XFile? selectedPhoto;
  final bool canChangePhoto;
  final VoidCallback? onTap;

  const EditableProfileAvatar({
    super.key,
    required this.name,
    required this.photoUrl,
    required this.selectedPhoto,
    required this.canChangePhoto,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasSelectedPhoto = selectedPhoto != null;
    final hasRemotePhoto = photoUrl != null && photoUrl!.isNotEmpty;

    Widget avatarContent;

    if (hasSelectedPhoto) {
      avatarContent = Image.file(
        File(selectedPhoto!.path),
        width: 96,
        height: 96,
        fit: BoxFit.cover,
        alignment: Alignment.center,
        filterQuality: FilterQuality.high,
        errorBuilder: (_, _, _) => Center(
          child: Text(
            initialsFromName(name),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 34,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      );
    } else if (hasRemotePhoto) {
      avatarContent = CachedRemoteImage(
        imageUrl: photoUrl!,
        cacheVariant: 'avatar',
        width: 96,
        height: 96,
        fit: BoxFit.cover,
        alignment: Alignment.center,
        filterQuality: FilterQuality.high,
        loadingWidget: Center(
          child: Text(
            initialsFromName(name),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 34,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        errorWidget: Center(
          child: Text(
            initialsFromName(name),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 34,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      );
    } else {
      avatarContent = Center(
        child: Text(
          initialsFromName(name),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 34,
            fontWeight: FontWeight.w900,
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: ssOrange,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.10),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: ClipOval(
              child: Stack(
                fit: StackFit.expand,
                children: [Container(color: ssOrange, child: avatarContent)],
              ),
            ),
          ),
          Positioned(
            right: -1,
            bottom: 2,
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: canChangePhoto ? ssOrange : ssText3,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2.5),
              ),
              child: Icon(
                canChangePhoto
                    ? Icons.edit_rounded
                    : Icons.lock_outline_rounded,
                color: Colors.white,
                size: canChangePhoto ? 17 : 15,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ProfileInfoCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool accent;

  const ProfileInfoCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.accent = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: accent ? ssOrangeLight : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent ? ssOrangeMid : ssBorder, width: 1.5),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: accent ? ssOrange : ssOrangeLight,
            child: Icon(
              icon,
              color: accent ? Colors.white : ssOrange,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: accent ? ssOrangeDark : ssTitle,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: ssText2,
                    fontSize: 12,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class NotificationsSettingsScreen extends StatefulWidget {
  final User user;

  const NotificationsSettingsScreen({super.key, required this.user});

  @override
  State<NotificationsSettingsScreen> createState() =>
      _NotificationsSettingsScreenState();
}

class _NotificationsSettingsScreenState
    extends State<NotificationsSettingsScreen> {
  bool saving = false;
  late Stream<DocumentSnapshot<Map<String, dynamic>>> userStream;
  late Stream<QuerySnapshot<Map<String, dynamic>>> groupsStream;

  DocumentReference<Map<String, dynamic>> get userRef =>
      FirebaseFirestore.instance.collection('users').doc(widget.user.uid);

  Query<Map<String, dynamic>> get groupsRef => FirebaseFirestore.instance
      .collection('users')
      .doc(widget.user.uid)
      .collection('groups')
      .orderBy('joinedAt', descending: true);

  @override
  void initState() {
    super.initState();
    userStream = userRef.snapshots();
    groupsStream = groupsRef.snapshots();
  }

  Future<void> _setUserNotificationSetting(String key, bool value) async {
    if (saving) return;

    setState(() => saving = true);

    try {
      await userRef.set({
        'notificationSettings': {
          key: value,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        'lastActiveAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (key == 'globalEnabled') {
        await actualizarEstadoTokensNotificacion(
          user: widget.user,
          enabled: value,
        );

        if (value) {
          await registrarTokenNotificaciones(widget.user);
        }
      }
    } catch (error) {
      if (!mounted) return;
      showSundaySnack(context, 'Error guardando notificaciones: $error');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _setGroupNotificationOverride(
    String groupId,
    String value,
  ) async {
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.user.uid)
          .collection('groups')
          .doc(groupId)
          .update({
            'notificationsOverride': value,
            'notificationsOverrideUpdatedAt': FieldValue.serverTimestamp(),
          });
    } catch (error) {
      if (!mounted) return;
      showSundaySnack(context, 'Error: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ssBg,
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(onBack: () => Navigator.pop(context)),
            Expanded(
              child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                stream: userStream,
                builder: (context, userSnapshot) {
                  final userData = userSnapshot.data?.data();
                  final settings = resolvedNotificationSettings(userData);
                  final globalOn = settings['globalEnabled'] ?? true;

                  if (userSnapshot.connectionState == ConnectionState.waiting) {
                    return const Center(
                      child: CircularProgressIndicator(color: ssOrange),
                    );
                  }

                  return ListView(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                    children: [
                      const Text(
                        'Notificaciones',
                        style: TextStyle(
                          color: ssTitle,
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 16),
                      SettingsSectionCard(
                        children: [
                          SettingsToggleRow(
                            title: 'Notificaciones activadas',
                            subtitle:
                                'Activa o desactiva todas las notificaciones',
                            value: globalOn,
                            onChanged: saving
                                ? null
                                : (value) => _setUserNotificationSetting(
                                    'globalEnabled',
                                    value,
                                  ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      const SettingsSectionTitle('TIPOS DE NOTIFICACIÓN'),
                      Opacity(
                        opacity: globalOn ? 1 : 0.4,
                        child: IgnorePointer(
                          ignoring: !globalOn,
                          child: SettingsSectionCard(
                            children: [
                              SettingsToggleRow(
                                title: 'Recordatorio del domingo',
                                subtitle:
                                    'Aviso el domingo para subir tu selfie',
                                value: settings['sundayTimeEnabled'] ?? true,
                                onChanged: saving
                                    ? null
                                    : (value) => _setUserNotificationSetting(
                                        'sundayTimeEnabled',
                                        value,
                                      ),
                              ),
                              const SettingsDivider(),
                              SettingsToggleRow(
                                title: 'Nuevos selfies',
                                subtitle:
                                    'Cuando alguien publica una selfie en tus grupos',
                                value: settings['newSelfiesEnabled'] ?? true,
                                onChanged: saving
                                    ? null
                                    : (value) => _setUserNotificationSetting(
                                        'newSelfiesEnabled',
                                        value,
                                      ),
                              ),
                              const SettingsDivider(),
                              SettingsToggleRow(
                                title: 'Recordatorios de amigos',
                                subtitle:
                                    'Cuando un amigo te envía un zumbido para recordarte subir tu selfie',
                                value:
                                    settings['friendRemindersEnabled'] ?? true,
                                onChanged: saving
                                    ? null
                                    : (value) => _setUserNotificationSetting(
                                        'friendRemindersEnabled',
                                        value,
                                      ),
                              ),
                              const SettingsDivider(),
                              SettingsToggleRow(
                                title: 'Nuevas reacciones',
                                subtitle:
                                    'Cuando alguien reacciona a tu selfie',
                                value: settings['reactionsEnabled'] ?? true,
                                onChanged: saving
                                    ? null
                                    : (value) => _setUserNotificationSetting(
                                        'reactionsEnabled',
                                        value,
                                      ),
                              ),
                              const SettingsDivider(),
                              SettingsToggleRow(
                                title: 'Miembros y solicitudes',
                                subtitle:
                                    'Cuando alguien solicita entrar, se une o te aceptan',
                                value: settings['newMembersEnabled'] ?? true,
                                onChanged: saving
                                    ? null
                                    : (value) => _setUserNotificationSetting(
                                        'newMembersEnabled',
                                        value,
                                      ),
                              ),
                              const SettingsDivider(),
                              SettingsToggleRow(
                                title: 'Resumen semanal',
                                subtitle:
                                    'Cada lunes con las fotos de la semana',
                                value:
                                    settings['weeklySummaryEnabled'] ?? false,
                                onChanged: saving
                                    ? null
                                    : (value) => _setUserNotificationSetting(
                                        'weeklySummaryEnabled',
                                        value,
                                      ),
                              ),
                              const SettingsDivider(),
                              SettingsToggleRow(
                                title: 'Mensajes del chat',
                                subtitle:
                                    'Cuando alguien escribe o envía un GIF en un chat de grupo',
                                value: settings['chatMessagesEnabled'] ?? false,
                                onChanged: saving
                                    ? null
                                    : (value) => _setUserNotificationSetting(
                                        'chatMessagesEnabled',
                                        value,
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      const SettingsSectionTitle('POR GRUPO'),
                      Opacity(
                        opacity: globalOn ? 1 : 0.4,
                        child: IgnorePointer(
                          ignoring: !globalOn,
                          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                            stream: groupsStream,
                            builder: (context, snapshot) {
                              final groups = snapshot.data?.docs ?? [];
                              if (groups.isEmpty) {
                                return const SettingsSectionCard(
                                  children: [
                                    SettingsInfoRow(
                                      title: 'Sin grupos todavía',
                                      subtitle:
                                          'Cuando tengas grupos, podrás ajustar las notificaciones de cada uno.',
                                    ),
                                  ],
                                );
                              }

                              return SettingsSectionCard(
                                children: List.generate(groups.length * 2 - 1, (
                                  index,
                                ) {
                                  if (index.isOdd) {
                                    return const SettingsDivider();
                                  }
                                  final doc = groups[index ~/ 2];
                                  final data = doc.data();
                                  final groupId = (data['groupId'] ?? doc.id)
                                      .toString();
                                  final groupName =
                                      data['displayNameSnapshot'] ?? 'Grupo';
                                  final rawGroupPhotoUrl =
                                      data['groupPhotoUrlSnapshot'];
                                  final groupPhotoUrl =
                                      rawGroupPhotoUrl is String
                                      ? rawGroupPhotoUrl
                                      : null;
                                  final value =
                                      data['notificationsOverride'] ?? 'on';
                                  return GroupNotificationRow(
                                    key: ValueKey(
                                      'group_notification_$groupId',
                                    ),
                                    groupId: groupId,
                                    groupName: groupName,
                                    groupPhotoUrl: groupPhotoUrl,
                                    value: value,
                                    enabled: globalOn && !saving,
                                    onChanged: (newValue) {
                                      _setGroupNotificationOverride(
                                        groupId,
                                        newValue,
                                      );
                                    },
                                  );
                                }),
                              );
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      const SettingsSectionTitle('DISPOSITIVO'),
                      Opacity(
                        opacity: globalOn ? 1 : 0.4,
                        child: IgnorePointer(
                          ignoring: !globalOn,
                          child: SettingsSectionCard(
                            children: [
                              SettingsToggleRow(
                                title: 'Sonido',
                                subtitle:
                                    'Permite que las notificaciones suenen si el sistema lo permite',
                                value: settings['soundEnabled'] ?? true,
                                onChanged: saving
                                    ? null
                                    : (value) => _setUserNotificationSetting(
                                        'soundEnabled',
                                        value,
                                      ),
                              ),
                              const SettingsDivider(),
                              SettingsToggleRow(
                                title: 'Vibración',
                                subtitle:
                                    'Permite vibración en avisos compatibles',
                                value: settings['vibrationEnabled'] ?? true,
                                onChanged: saving
                                    ? null
                                    : (value) => _setUserNotificationSetting(
                                        'vibrationEnabled',
                                        value,
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AppSettingsScreen extends StatefulWidget {
  final User user;

  const AppSettingsScreen({super.key, required this.user});

  @override
  State<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends State<AppSettingsScreen> {
  bool clearDone = false;
  bool clearingCache = false;
  bool deletingAccount = false;

  Future<void> _confirmClearCache() async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 36),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: ssBorder,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  '¿Borrar el contenido descargado?',
                  style: TextStyle(
                    color: ssText,
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'No afecta al contenido en la nube. Podrás volver a descargarlo cuando quieras.',
                  style: TextStyle(color: ssText2, fontSize: 14, height: 1.35),
                ),
                const SizedBox(height: 20),
                SundayButton(
                  text: 'Borrar caché',
                  onPressed: () => Navigator.pop(sheetContext, true),
                ),
                const SizedBox(height: 10),
                SundayButton(
                  text: 'Cancelar',
                  variant: SundayButtonVariant.ghost,
                  onPressed: () => Navigator.pop(sheetContext, false),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (confirmed == true) {
      setState(() => clearingCache = true);
      try {
        final deletedCount = await LocalPhotoCache.instance.clear();
        if (!mounted) return;
        setState(() {
          clearingCache = false;
          clearDone = true;
        });
        showSundaySnack(
          context,
          deletedCount == 0
              ? 'La caché local ya estaba vacía'
              : 'Caché local borrada',
        );
        await Future<void>.delayed(const Duration(seconds: 3));
        if (mounted) setState(() => clearDone = false);
      } catch (error) {
        if (!mounted) return;
        setState(() => clearingCache = false);
        showSundaySnack(context, 'No se pudo borrar la caché local: $error');
      }
    }
  }

  Future<void> _confirmDeleteAccount() async {
    if (deletingAccount) return;

    final confirmationController = TextEditingController();
    var canDelete = false;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
              ),
              title: const Text('Borrar cuenta definitivamente'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Se borrarán tu perfil, tus selfies, reacciones, mensajes y acceso a Sunday Selfie. Esta acción no se puede deshacer.',
                    style: TextStyle(color: ssText2, height: 1.35),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Si eres la única persona administradora de un grupo, otro miembro pasará a administrarlo. Los reportes de seguridad pueden conservarse para revisión.',
                    style: TextStyle(color: ssText2, height: 1.35),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Escribe BORRAR para confirmar:',
                    style: TextStyle(
                      color: ssText,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: confirmationController,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      hintText: 'BORRAR',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (value) {
                      final nextCanDelete = value.trim() == 'BORRAR';
                      if (nextCanDelete == canDelete) return;
                      setDialogState(() => canDelete = nextCanDelete);
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancelar'),
                ),
                TextButton(
                  onPressed: canDelete
                      ? () => Navigator.pop(dialogContext, true)
                      : null,
                  child: const Text(
                    'Borrar definitivamente',
                    style: TextStyle(
                      color: Color(0xFFE74C3C),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
    confirmationController.dispose();

    if (confirmed != true || !mounted) return;

    setState(() => deletingAccount = true);

    try {
      await borrarCuentaSundaySelfie();
      await FirebaseAuth.instance.signOut();
    } catch (error) {
      if (!mounted) return;
      showSundaySnack(context, 'Error borrando la cuenta: $error');
    } finally {
      if (mounted) setState(() => deletingAccount = false);
    }
  }

  Future<void> _confirmSignOut() async {
    final shouldSignOut = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          title: const Text('Cerrar sesión'),
          content: const Text(
            '¿Quieres salir de Sunday Selfie en este dispositivo?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancelar'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text(
                'Salir',
                style: TextStyle(
                  color: ssOrangeDark,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        );
      },
    );

    if (shouldSignOut == true) {
      await FirebaseAuth.instance.signOut();
    }
  }

  void _openLegalScreen({
    required String title,
    required List<LegalTextSection> sections,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LegalTextScreen(title: title, sections: sections),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ssBg,
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(onBack: () => Navigator.pop(context)),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                children: [
                  const Text(
                    'Ajustes',
                    style: TextStyle(
                      color: ssText,
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 20),
                  const SettingsSectionTitle('ALMACENAMIENTO'),
                  SettingsSectionCard(
                    children: [
                      SettingsNavigationRow(
                        title: clearingCache
                            ? 'Borrando caché...'
                            : clearDone
                            ? '✅ Caché borrada'
                            : 'Borrar caché local',
                        subtitle: 'Libera espacio descargado localmente',
                        titleColor: clearDone
                            ? const Color(0xFF4CAF50)
                            : ssText,
                        showChevron: !clearDone && !clearingCache,
                        onTap: clearDone || clearingCache
                            ? null
                            : _confirmClearCache,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: Text(
                      'Las fotos originales permanecen en la nube',
                      style: TextStyle(
                        color: ssText3,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const SettingsSectionTitle('LEGAL'),
                  SettingsSectionCard(
                    children: [
                      SettingsNavigationRow(
                        title: 'Política de privacidad',
                        onTap: () => _openLegalScreen(
                          title: 'Política de privacidad',
                          sections: kPrivacyPolicySections,
                        ),
                      ),
                      const SettingsDivider(),
                      SettingsNavigationRow(
                        title: 'Términos de uso',
                        onTap: () => _openLegalScreen(
                          title: 'Términos de uso',
                          sections: kTermsOfUseSections,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  const SettingsSectionTitle('CUENTA'),
                  SettingsSectionCard(
                    children: [
                      SettingsNavigationRow(
                        title: deletingAccount
                            ? 'Borrando cuenta...'
                            : 'Borrar cuenta',
                        subtitle:
                            'Elimina definitivamente tu perfil y contenido personal',
                        titleColor: const Color(0xFFE74C3C),
                        showChevron: false,
                        onTap: deletingAccount ? null : _confirmDeleteAccount,
                      ),
                      const SettingsDivider(),
                      SettingsNavigationRow(
                        title: 'Cerrar sesión',
                        subtitle: 'Sale de Sunday Selfie en este dispositivo',
                        titleColor: const Color(0xFFE74C3C),
                        showChevron: false,
                        onTap: deletingAccount ? null : _confirmSignOut,
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Sunday Selfie v1.0 (beta)',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: ssText3,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class LegalTextSection {
  final String title;
  final String body;

  const LegalTextSection({required this.title, required this.body});
}

const List<LegalTextSection> kPrivacyPolicySections = [
  LegalTextSection(title: 'Última actualización', body: '22 de junio de 2026.'),
  LegalTextSection(
    title: 'Quién gestiona Sunday Selfie',
    body:
        'Sunday Selfie es la app del proyecto Sunday Selfie. Para consultas de privacidad puedes escribir a sundayselfie2026@gmail.com.',
  ),
  LegalTextSection(
    title: 'Datos que tratamos',
    body:
        'Tratamos los datos necesarios para que la app funcione: identificador de usuario, nombre, correo de inicio de sesión cuando el proveedor lo facilita, foto de perfil, grupos a los que perteneces, selfies, miniaturas, reacciones, mensajes del chat semanal, reportes, sugerencias, preferencias de notificaciones, tokens de notificación y datos técnicos básicos de uso y seguridad.',
  ),
  LegalTextSection(
    title: 'Fotos, cámara y validación',
    body:
        'Usamos la cámara o la galería solo cuando decides hacer o subir una selfie. La comprobación facial se realiza para validar que la publicación es una selfie. Guardamos la foto y una miniatura para mostrarla en tus grupos y en tu historial.',
  ),
  LegalTextSection(
    title: 'Para qué usamos los datos',
    body:
        'Usamos tus datos para crear y proteger tu cuenta, mostrar tus selfies dentro de los grupos, calcular rachas, permitir reacciones y chats, enviar notificaciones, revisar reportes, responder sugerencias, prevenir abusos y mantener la seguridad de la app.',
  ),
  LegalTextSection(
    title: 'Servicios externos',
    body:
        'La app usa servicios de Firebase y Google para autenticación, base de datos, almacenamiento, funciones en la nube, notificaciones, analítica técnica y anuncios recompensados. Si envías sugerencias, podemos recibirlas por correo en la dirección del proyecto.',
  ),
  LegalTextSection(
    title: 'Quién puede ver tu contenido',
    body:
        'Los miembros de un grupo pueden ver las selfies, nombre, foto de perfil, reacciones y mensajes compartidos dentro de ese grupo. Los reportes se tratan de forma privada para revisión. No vendemos tus datos personales.',
  ),
  LegalTextSection(
    title: 'Conservación y borrado',
    body:
        'Conservamos el contenido mientras mantengas tu cuenta o mientras sea necesario para prestar el servicio. Desde Ajustes puedes borrar la caché local o solicitar el borrado definitivo de tu cuenta y contenido personal. Algunos registros de seguridad o reportes pueden conservarse durante el tiempo necesario para proteger a la comunidad y cumplir obligaciones legales.',
  ),
  LegalTextSection(
    title: 'Tus derechos',
    body:
        'Puedes pedir acceso, corrección, oposición, limitación, portabilidad o eliminación de tus datos escribiendo a sundayselfie2026@gmail.com. También puedes retirar permisos del dispositivo desde los ajustes del sistema.',
  ),
  LegalTextSection(
    title: 'Cambios',
    body:
        'Si actualizamos esta política, cambiaremos la fecha de actualización y publicaremos la nueva versión dentro de la app.',
  ),
];

const List<LegalTextSection> kTermsOfUseSections = [
  LegalTextSection(title: 'Última actualización', body: '22 de junio de 2026.'),
  LegalTextSection(
    title: 'Aceptación',
    body:
        'Al usar Sunday Selfie aceptas estos términos. Si no estás de acuerdo, no uses la app.',
  ),
  LegalTextSection(
    title: 'Uso de la app',
    body:
        'Sunday Selfie está pensada para compartir una selfie semanal con tus grupos. Debes usar la app de forma respetuosa, mantener tu cuenta protegida y no intentar acceder a grupos, cuentas o contenido que no te correspondan.',
  ),
  LegalTextSection(
    title: 'Tu contenido',
    body:
        'Tú conservas tus derechos sobre las selfies, mensajes, reacciones y sugerencias que compartes. Nos autorizas a alojar, procesar y mostrar ese contenido dentro de la app para prestar el servicio, crear miniaturas, notificaciones, rachas e historial.',
  ),
  LegalTextSection(
    title: 'Contenido no permitido',
    body:
        'No publiques contenido ilegal, ofensivo, acosador, discriminatorio, sexual explícito, violento, que vulnere derechos de otras personas o que exponga datos personales de terceros sin permiso. Podemos retirar contenido, limitar funciones o cerrar cuentas cuando sea necesario para proteger la app y sus usuarios.',
  ),
  LegalTextSection(
    title: 'Grupos y reportes',
    body:
        'Los administradores gestionan la participación en sus grupos. Cualquier miembro puede reportar contenido para revisión privada. Los reportes falsos o abusivos también pueden dar lugar a restricciones.',
  ),
  LegalTextSection(
    title: 'Anuncios y funciones beta',
    body:
        'Algunas funciones pueden requerir ver un anuncio recompensado o estar disponibles solo en beta. Podemos cambiar, pausar o retirar funciones mientras mejoramos Sunday Selfie.',
  ),
  LegalTextSection(
    title: 'Disponibilidad',
    body:
        'Trabajamos para que Sunday Selfie funcione bien, pero no garantizamos disponibilidad continua ni ausencia total de errores. No nos hacemos responsables de pérdidas derivadas de interrupciones, fallos técnicos o uso indebido de la app.',
  ),
  LegalTextSection(
    title: 'Baja',
    body:
        'Puedes cerrar sesión o solicitar el borrado definitivo de tu cuenta desde Ajustes. Al borrar la cuenta perderás acceso a tu perfil y contenido personal asociado.',
  ),
  LegalTextSection(
    title: 'Contacto',
    body:
        'Para dudas, sugerencias o reclamaciones sobre estos términos, escribe a sundayselfie2026@gmail.com.',
  ),
];

class LegalTextScreen extends StatelessWidget {
  final String title;
  final List<LegalTextSection> sections;

  const LegalTextScreen({
    super.key,
    required this.title,
    required this.sections,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ssBg,
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(onBack: () => Navigator.pop(context)),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: ssText,
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 16),
                  SundayCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var index = 0; index < sections.length; index++)
                          LegalTextSectionBlock(
                            section: sections[index],
                            isLast: index == sections.length - 1,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class LegalTextSectionBlock extends StatelessWidget {
  final LegalTextSection section;
  final bool isLast;

  const LegalTextSectionBlock({
    super.key,
    required this.section,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            section.title,
            style: const TextStyle(
              color: ssTitle,
              fontSize: 15,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            section.body,
            style: const TextStyle(
              color: ssText2,
              fontSize: 13.5,
              height: 1.42,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class ProfileAvatar extends StatelessWidget {
  final String name;
  final String? photoUrl;
  final double size;
  final VoidCallback? onTap;

  const ProfileAvatar({
    super.key,
    required this.name,
    required this.photoUrl,
    required this.size,
    this.onTap,
  });

  bool get hasPhoto => photoUrl != null && photoUrl!.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final avatar = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: ssOrange,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: ssOrange.withValues(alpha: 0.30),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipOval(
        child: Container(
          color: ssOrange,
          child: hasPhoto
              ? Stack(
                  fit: StackFit.expand,
                  children: [
                    CachedRemoteImage(
                      imageUrl: photoUrl!,
                      cacheVariant: 'avatar',
                      fit: BoxFit.cover,
                      alignment: Alignment.center,
                      filterQuality: FilterQuality.high,
                      loadingWidget: Center(
                        child: Text(
                          initialsFromName(name),
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: size * 0.36,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      errorWidget: Center(
                        child: Text(
                          initialsFromName(name),
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: size * 0.36,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: ssOrange.withValues(alpha: 0.14),
                        backgroundBlendMode: BlendMode.softLight,
                      ),
                    ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: const Alignment(-0.45, -0.55),
                          radius: 1.2,
                          colors: [
                            Colors.white.withValues(alpha: 0.08),
                            Colors.transparent,
                            ssOrangeDark.withValues(alpha: 0.18),
                          ],
                          stops: const [0, 0.58, 1],
                        ),
                      ),
                    ),
                  ],
                )
              : Center(
                  child: Text(
                    initialsFromName(name),
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: size * 0.36,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
        ),
      ),
    );

    if (onTap == null) return avatar;

    return Semantics(
      button: true,
      label: 'Editar perfil',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: MouseRegion(cursor: SystemMouseCursors.click, child: avatar),
      ),
    );
  }
}

class ProfileStatsBar extends StatelessWidget {
  final int groupsCount;
  final int activeWeeks;
  final int selfiesCount;

  const ProfileStatsBar({
    super.key,
    required this.groupsCount,
    required this.activeWeeks,
    required this.selfiesCount,
  });

  @override
  Widget build(BuildContext context) {
    final stats = [
      ('Grupos', groupsCount),
      ('Semanas activo', activeWeeks),
      ('Selfies', selfiesCount),
    ];

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: ssBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: List.generate(stats.length, (index) {
          final item = stats[index];
          return Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                border: index < stats.length - 1
                    ? const Border(right: BorderSide(color: ssBorder))
                    : null,
              ),
              child: Column(
                children: [
                  Text(
                    '${item.$2}',
                    style: const TextStyle(
                      color: ssOrange,
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      height: 1,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    item.$1,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: ssText3,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }
}

enum ProfileLineIconKind {
  notifications,
  editProfile,
  suggestions,
  settings,
  selfies,
}

class ProfileLineIcon extends StatelessWidget {
  final ProfileLineIconKind icon;
  final Color color;
  final double size;

  const ProfileLineIcon({
    super.key,
    required this.icon,
    required this.color,
    this.size = 30,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _ProfileLineIconPainter(icon, color)),
    );
  }
}

class _ProfileLineIconPainter extends CustomPainter {
  final ProfileLineIconKind icon;
  final Color color;

  const _ProfileLineIconPainter(this.icon, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    final offset = Offset((size.width - side) / 2, (size.height - side) / 2);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.scale(side / 100);

    switch (icon) {
      case ProfileLineIconKind.notifications:
        _paintBell(canvas, paint);
        break;
      case ProfileLineIconKind.editProfile:
        _paintUser(canvas, paint);
        break;
      case ProfileLineIconKind.suggestions:
        _paintBulb(canvas, paint);
        break;
      case ProfileLineIconKind.settings:
        _paintSunSettings(canvas, paint);
        break;
      case ProfileLineIconKind.selfies:
        _paintSelfiesGrid(canvas, paint);
        break;
    }

    canvas.restore();
  }

  void _paintBell(Canvas canvas, Paint paint) {
    final bell = Path()
      ..moveTo(25, 63)
      ..lineTo(75, 63)
      ..moveTo(32, 63)
      ..lineTo(32, 43)
      ..cubicTo(32, 29, 40, 20, 50, 20)
      ..cubicTo(60, 20, 68, 29, 68, 43)
      ..lineTo(68, 63);
    canvas.drawPath(bell, paint);
    canvas.drawArc(
      const Rect.fromLTWH(42, 59, 16, 20),
      0,
      math.pi,
      false,
      paint,
    );
  }

  void _paintUser(Canvas canvas, Paint paint) {
    canvas.drawCircle(const Offset(50, 34), 14, paint);

    final shoulders = Path()
      ..moveTo(23, 80)
      ..cubicTo(23, 63, 34, 54, 50, 54)
      ..cubicTo(66, 54, 77, 63, 77, 80);
    canvas.drawPath(shoulders, paint);
  }

  void _paintBulb(Canvas canvas, Paint paint) {
    final bulb = Path()
      ..moveTo(50, 18)
      ..cubicTo(36, 18, 26, 28, 26, 42)
      ..cubicTo(26, 52, 32, 59, 39, 64)
      ..cubicTo(43, 67, 44, 70, 44, 73)
      ..lineTo(56, 73)
      ..cubicTo(56, 70, 57, 67, 61, 64)
      ..cubicTo(68, 59, 74, 52, 74, 42)
      ..cubicTo(74, 28, 64, 18, 50, 18);
    canvas.drawPath(bulb, paint);
    canvas.drawLine(const Offset(42, 80), const Offset(58, 80), paint);
    canvas.drawLine(const Offset(46, 87), const Offset(54, 87), paint);
  }

  void _paintSunSettings(Canvas canvas, Paint paint) {
    canvas.drawCircle(const Offset(50, 50), 5, paint);

    for (var index = 0; index < 8; index += 1) {
      final angle = math.pi * 2 * index / 8;
      final direction = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(
        Offset(50 + direction.dx * 18, 50 + direction.dy * 18),
        Offset(50 + direction.dx * 29, 50 + direction.dy * 29),
        paint,
      );
    }
  }

  void _paintSelfiesGrid(Canvas canvas, Paint paint) {
    const radius = Radius.circular(8);
    const rects = [
      Rect.fromLTWH(17, 17, 26, 26),
      Rect.fromLTWH(57, 17, 26, 26),
      Rect.fromLTWH(17, 57, 26, 26),
      Rect.fromLTWH(57, 57, 26, 26),
    ];

    for (final rect in rects) {
      canvas.drawRRect(RRect.fromRectAndRadius(rect, radius), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ProfileLineIconPainter oldDelegate) {
    return oldDelegate.icon != icon || oldDelegate.color != color;
  }
}

class ProfileSelfiesShortcut extends StatelessWidget {
  final int selfiesCount;
  final VoidCallback onTap;

  const ProfileSelfiesShortcut({
    super.key,
    required this.selfiesCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [ssOrange, Color(0xFFF7B733)]),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.20),
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: const ProfileLineIcon(
                icon: ProfileLineIconKind.selfies,
                color: ssBg,
                size: 29,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Mis Sunday Selfies',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$selfiesCount selfies publicados',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.82),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: Colors.white.withValues(alpha: 0.85),
            ),
          ],
        ),
      ),
    );
  }
}

class ProfileMenuRow extends StatelessWidget {
  final ProfileLineIconKind icon;
  final String label;
  final VoidCallback onTap;

  const ProfileMenuRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: ssBorder),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 36,
                  child: Center(
                    child: ProfileLineIcon(
                      icon: icon,
                      color: ssOrange,
                      size: 30,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(
                      color: ssText,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: ssText3,
                  size: 22,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SettingsSectionTitle extends StatelessWidget {
  final String text;

  const SettingsSectionTitle(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: const TextStyle(
          color: ssText3,
          fontSize: 12,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class SettingsSectionCard extends StatelessWidget {
  final List<Widget> children;

  const SettingsSectionCard({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ssBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}

class SettingsDivider extends StatelessWidget {
  const SettingsDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return const Divider(height: 1, thickness: 1, color: ssSeparator);
  }
}

class SettingsToggleRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  const SettingsToggleRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: ssText,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: const TextStyle(
                      color: ssText3,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
          ),
          SundaySwitch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class SettingsInfoRow extends StatelessWidget {
  final String title;
  final String subtitle;

  const SettingsInfoRow({
    super.key,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: ssText,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: const TextStyle(color: ssText3, fontSize: 12, height: 1.35),
          ),
        ],
      ),
    );
  }
}

class SettingsNavigationRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Color titleColor;
  final bool showChevron;
  final VoidCallback? onTap;

  const SettingsNavigationRow({
    super.key,
    required this.title,
    this.subtitle,
    this.titleColor = ssText,
    this.showChevron = true,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: titleColor,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: const TextStyle(
                          color: ssText3,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (showChevron)
                const Icon(
                  Icons.chevron_right_rounded,
                  color: ssText3,
                  size: 22,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class GroupNotificationRow extends StatefulWidget {
  final String groupId;
  final String groupName;
  final String? groupPhotoUrl;
  final String value;
  final bool enabled;
  final ValueChanged<String> onChanged;

  const GroupNotificationRow({
    super.key,
    required this.groupId,
    required this.groupName,
    required this.groupPhotoUrl,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  @override
  State<GroupNotificationRow> createState() => _GroupNotificationRowState();
}

class _GroupNotificationRowState extends State<GroupNotificationRow> {
  late Stream<DocumentSnapshot<Map<String, dynamic>>> groupStream;

  @override
  void initState() {
    super.initState();
    groupStream = FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.groupId)
        .snapshots();
  }

  @override
  void didUpdateWidget(covariant GroupNotificationRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.groupId != widget.groupId) {
      groupStream = FirebaseFirestore.instance
          .collection('groups')
          .doc(widget.groupId)
          .snapshots();
    }
  }

  @override
  Widget build(BuildContext context) {
    final normalized = widget.value == 'off' ? 'off' : 'on';

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: groupStream,
      builder: (context, snapshot) {
        final groupData = snapshot.data?.data();
        final resolvedName = (groupData?['name'] ?? widget.groupName)
            .toString();
        final rawResolvedPhotoUrl = groupData?['photoUrl'];
        final resolvedPhotoUrl =
            rawResolvedPhotoUrl is String &&
                rawResolvedPhotoUrl.trim().isNotEmpty
            ? rawResolvedPhotoUrl.trim()
            : widget.groupPhotoUrl;

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              GroupIconSmall(name: resolvedName, photoUrl: resolvedPhotoUrl),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  formatGroupDisplayName(resolvedName),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: ssText,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Container(
                height: 34,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: ssBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: ssBorder),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: normalized,
                    iconSize: 18,
                    borderRadius: BorderRadius.circular(12),
                    style: const TextStyle(
                      color: ssText2,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                    items: const [
                      DropdownMenuItem(value: 'on', child: Text('Activadas')),
                      DropdownMenuItem(
                        value: 'off',
                        child: Text('Desactivadas'),
                      ),
                    ],
                    onChanged: widget.enabled
                        ? (newValue) {
                            if (newValue != null) widget.onChanged(newValue);
                          }
                        : null,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class GroupIconSmall extends StatelessWidget {
  final String name;
  final String? photoUrl;

  const GroupIconSmall({super.key, required this.name, required this.photoUrl});

  bool get hasPhoto => photoUrl != null && photoUrl!.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final emoji = extractLastEmoji(name);

    if (hasPhoto) {
      return Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(10)),
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: ssOrangeMid, width: 1.2),
        ),
        clipBehavior: Clip.antiAlias,
        child: CachedRemoteImage(
          imageUrl: photoUrl!,
          cacheVariant: 'avatar',
          width: 36,
          height: 36,
          fit: BoxFit.cover,
          alignment: Alignment.center,
          filterQuality: FilterQuality.high,
          loadingWidget: Center(
            child: Text(
              emoji ?? initialsFromName(name),
              style: const TextStyle(
                color: ssOrangeDark,
                fontSize: 16,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          errorWidget: Center(
            child: Text(
              emoji ?? initialsFromName(name),
              style: const TextStyle(
                color: ssOrangeDark,
                fontSize: 16,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: ssOrangeLight,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ssBorder),
      ),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      child: Text(
        emoji ?? initialsFromName(name),
        style: const TextStyle(
          color: ssOrangeDark,
          fontSize: 16,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class SundaySwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;

  const SundaySwitch({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onChanged == null ? null : () => onChanged!(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 46,
        height: 26,
        decoration: BoxDecoration(
          color: value ? ssOrange : ssBorder,
          borderRadius: BorderRadius.circular(13),
        ),
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        padding: const EdgeInsets.all(3),
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.20),
                blurRadius: 4,
                offset: const Offset(0, 1),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<int> countUserSelfies(
  String userUid,
  List<QueryDocumentSnapshot<Map<String, dynamic>>> groupDocs,
) async {
  final firestore = FirebaseFirestore.instance;
  var count = 0;

  for (final groupDoc in groupDocs) {
    final data = groupDoc.data();
    final groupId = data['groupId'] ?? groupDoc.id;
    try {
      final weeks = await firestore
          .collection('groups')
          .doc(groupId)
          .collection('weeks')
          .limit(50)
          .get();
      for (final week in weeks.docs) {
        final post = await week.reference
            .collection('posts')
            .doc(userUid)
            .get();
        if (post.exists) count += 1;
      }
    } catch (_) {
      // Ignoramos grupos antiguos o sin permisos para no bloquear la pantalla.
    }
  }

  return count;
}

int activeWeeksFromGroups(
  List<QueryDocumentSnapshot<Map<String, dynamic>>> groupDocs,
) {
  if (groupDocs.isEmpty) return 0;

  final joinedDates = groupDocs
      .map((doc) => timestampToDate(doc.data()['joinedAt']))
      .whereType<DateTime>()
      .toList();

  if (joinedDates.isEmpty) return 0;

  joinedDates.sort();
  final first = joinedDates.first;
  final now = DateTime.now();
  if (first.isAfter(now)) return 0;

  final firstDay = DateTime(first.year, first.month, first.day);
  final firstSunday = firstDay.add(
    Duration(
      days: first.weekday == DateTime.sunday
          ? 7
          : DateTime.sunday - first.weekday,
    ),
  );

  if (now.isBefore(firstSunday)) return 0;

  return (now.difference(firstSunday).inDays ~/ 7 + 1).clamp(1, 9999).toInt();
}

String monthName(int month) {
  const months = [
    'enero',
    'febrero',
    'marzo',
    'abril',
    'mayo',
    'junio',
    'julio',
    'agosto',
    'septiembre',
    'octubre',
    'noviembre',
    'diciembre',
  ];
  if (month < 1 || month > 12) return '';
  return months[month - 1];
}

class CameraCaptureScreen extends StatefulWidget {
  final String? groupName;

  const CameraCaptureScreen({super.key, this.groupName});

  @override
  State<CameraCaptureScreen> createState() => _CameraCaptureScreenState();
}

class _CameraCaptureScreenState extends State<CameraCaptureScreen> {
  CameraController? controller;
  List<CameraDescription> cameras = [];
  int cameraIndex = 0;
  bool loading = true;
  bool taking = false;
  bool switching = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final available = await availableCameras();
      if (available.isEmpty) {
        setState(() {
          error =
              'No se ha encontrado cámara disponible. En el simulador iOS esto es normal.';
          loading = false;
        });
        return;
      }

      final frontIndex = available.indexWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
      );

      cameras = available;
      cameraIndex = frontIndex >= 0 ? frontIndex : 0;
      await _startController(cameras[cameraIndex]);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = 'Error iniciando cámara: $e';
        loading = false;
      });
    }
  }

  Future<void> _startController(CameraDescription camera) async {
    final oldController = controller;
    controller = null;
    await oldController?.dispose();

    final camController = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    await camController.initialize();

    if (!mounted) {
      await camController.dispose();
      return;
    }

    setState(() {
      controller = camController;
      loading = false;
      switching = false;
      error = null;
    });
  }

  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }

  Future<void> _switchCamera() async {
    if (cameras.length < 2 || switching || taking) return;

    setState(() => switching = true);
    try {
      cameraIndex = (cameraIndex + 1) % cameras.length;
      await _startController(cameras[cameraIndex]);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = 'Error cambiando cámara: $e';
        switching = false;
      });
    }
  }

  Future<void> _takePicture() async {
    final cam = controller;
    if (cam == null || !cam.value.isInitialized || taking || switching) return;

    setState(() => taking = true);
    try {
      final picture = await cam.takePicture();
      if (!mounted) return;
      Navigator.pop(context, picture);
    } catch (e) {
      if (!mounted) return;
      showSundaySnack(context, 'Error haciendo foto: $e');
      setState(() => taking = false);
    }
  }

  Widget _buildPreview() {
    final cam = controller;

    if (loading || switching) {
      return const Center(child: CircularProgressIndicator(color: ssOrange));
    }

    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 86,
                height: 86,
                decoration: const BoxDecoration(
                  color: ssOrange,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.no_photography_rounded,
                  color: Colors.white,
                  size: 40,
                ),
              ),
              const SizedBox(height: 22),
              Text(
                error!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  height: 1.45,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 22),
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: const Text(
                    'Volver',
                    style: TextStyle(
                      color: ssText,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (cam == null || !cam.value.isInitialized) {
      return const Center(child: CircularProgressIndicator(color: ssOrange));
    }

    return Center(
      child: SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: cam.value.previewSize?.height ?? 1,
            height: cam.value.previewSize?.width ?? 1,
            child: CameraPreview(cam),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final cameraReady =
        error == null &&
        !loading &&
        !switching &&
        controller != null &&
        controller!.value.isInitialized;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: _buildPreview()),
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.70),
                      Colors.transparent,
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.80),
                    ],
                    stops: const [0, 0.22, 0.68, 1],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 18,
            right: 18,
            top: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Row(
                  children: [
                    CircleIconButton(
                      icon: Icons.close_rounded,
                      dark: true,
                      onTap: () => Navigator.pop(context),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Transform.translate(
                        offset: const Offset(0, -3),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              'Sunday Selfie',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            if (widget.groupName != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                widget.groupName!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.75),
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Opacity(
                      opacity: cameras.length >= 2 && cameraReady ? 1 : 0.35,
                      child: CircleIconButton(
                        icon: Icons.cameraswitch_rounded,
                        dark: true,
                        onTap: () {
                          if (cameras.length >= 2 && cameraReady) {
                            _switchCamera();
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (cameraReady)
            Positioned(
              left: 24,
              right: 24,
              bottom: 28 + bottomPadding,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(28),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.34),
                          borderRadius: BorderRadius.circular(28),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.14),
                          ),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.lock_rounded,
                              color: Colors.white70,
                              size: 18,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Solo cámara in-app · sin galería',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.78),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 22),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(width: 76, child: Container()),
                      GestureDetector(
                        onTap: _takePicture,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          width: taking ? 82 : 88,
                          height: taking ? 82 : 88,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 5),
                            boxShadow: [
                              BoxShadow(
                                color: ssOrange.withValues(alpha: 0.35),
                                blurRadius: 30,
                                offset: const Offset(0, 10),
                              ),
                            ],
                          ),
                          child: Center(
                            child: Container(
                              width: taking ? 56 : 64,
                              height: taking ? 56 : 64,
                              decoration: BoxDecoration(
                                color: taking ? ssOrange : Colors.white,
                                shape: BoxShape.circle,
                              ),
                              child: taking
                                  ? const Padding(
                                      padding: EdgeInsets.all(15),
                                      child: CircularProgressIndicator(
                                        color: Colors.white,
                                        strokeWidth: 3,
                                      ),
                                    )
                                  : null,
                            ),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 76,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: GestureDetector(
                            onTap: () {
                              if (cameras.length >= 2) {
                                _switchCamera();
                              }
                            },
                            child: Container(
                              width: 54,
                              height: 54,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(
                                  alpha: cameras.length < 2 ? 0.18 : 0.28,
                                ),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.18),
                                ),
                              ),
                              child: const Icon(
                                Icons.flip_camera_ios_rounded,
                                color: Colors.white,
                                size: 24,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class PlaceholderTabScreen extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;

  const PlaceholderTabScreen({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ssBg,
      body: SafeArea(
        child: Column(
          children: [
            const AppHeader(),
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: SundayCard(
                    child: EmptyStateContent(
                      icon: icon,
                      title: title,
                      subtitle: subtitle,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AppHeader extends StatelessWidget {
  final VoidCallback? onBack;
  final Widget? right;
  final String? subtitle;
  final TextStyle? subtitleStyle;
  final bool subtitleCenteredInBottomGap;
  final bool logoTapToHome;

  const AppHeader({
    super.key,
    this.onBack,
    this.right,
    this.subtitle,
    this.subtitleStyle,
    this.subtitleCenteredInBottomGap = false,
    this.logoTapToHome = true,
  });

  void _goToGroups(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => SundayShell(user: user, initialIndex: 0),
      ),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final logo = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: logoTapToHome ? () => _goToGroups(context) : null,
      child: const SundayLogo(size: 34),
    );
    final subtitleText = subtitle == null
        ? null
        : ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.62,
            ),
            child: Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style:
                  subtitleStyle ??
                  const TextStyle(color: ssText3, fontSize: 12),
            ),
          );

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, ssHeaderTopPadding, 20, 10),
      child: SizedBox(
        width: double.infinity,
        height: subtitle == null ? 58 : 74,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (onBack != null)
              Positioned(
                left: -8,
                top: ssHeaderActionTop,
                child: SizedBox.square(
                  dimension: ssHeaderActionSize,
                  child: IconButton(
                    onPressed: onBack,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: ssHeaderActionSize,
                      height: ssHeaderActionSize,
                    ),
                    icon: const SundayHeaderBackIcon(),
                  ),
                ),
              ),
            if (subtitleCenteredInBottomGap && subtitleText != null) ...[
              Positioned(left: 0, right: 0, top: 2, child: Center(child: logo)),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Center(child: subtitleText),
              ),
            ] else
              Center(
                child: Transform.translate(
                  offset: const Offset(0, -3),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      logo,
                      if (subtitleText != null) ...[
                        const SizedBox(height: 2),
                        subtitleText,
                      ],
                    ],
                  ),
                ),
              ),
            if (right != null)
              Positioned(
                right: subtitle == null ? -2 : -6,
                top: ssHeaderActionTop,
                child: SizedBox.square(
                  dimension: ssHeaderActionSize,
                  child: Align(alignment: Alignment.centerRight, child: right!),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class SundayLogo extends StatelessWidget {
  final double size;

  const SundayLogo({super.key, this.size = 28});

  @override
  Widget build(BuildContext context) {
    return Text(
      'Sunday Selfie',
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.visible,
      style: GoogleFonts.dancingScript(
        color: ssOrange,
        fontSize: size * 1.035 + 2,
        fontWeight: FontWeight.w900,
        letterSpacing: 0.15,
        height: 1.15,
        shadows: [
          Shadow(
            color: ssOrange.withValues(alpha: 0.34),
            offset: const Offset(0.24, 0),
            blurRadius: 0,
          ),
        ],
      ),
    );
  }
}

class SundaySelfieLogoMark extends StatelessWidget {
  final double size;

  const SundaySelfieLogoMark({super.key, required this.size});

  @override
  Widget build(BuildContext context) {
    return Image.memory(
      base64Decode(kSundaySelfieLogoMarkBase64),
      width: size,
      height: size,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      filterQuality: FilterQuality.high,
    );
  }
}

class SundayWindowCountdownCard extends StatelessWidget {
  final EdgeInsetsGeometry? margin;
  final bool compact;

  const SundayWindowCountdownCard({
    super.key,
    this.margin,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<int>(
      stream: Stream.periodic(const Duration(seconds: 1), (value) => value),
      builder: (context, snapshot) {
        final now = DateTime.now();
        final window = obtenerSundayWindowState(now: now);
        final remaining = obtenerTiempoRestanteVentana(window, now: now);
        final isOpen = window.canUpload;

        return Container(
          margin: margin,
          padding: EdgeInsets.all(compact ? 12 : 16),
          decoration: BoxDecoration(
            color: isOpen ? ssOrangeLight : ssSurface,
            borderRadius: BorderRadius.circular(compact ? 16 : 18),
            border: Border.all(
              color: isOpen ? ssOrangeMid : ssBorder,
              width: 1.4,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.035),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: compact ? 40 : 48,
                height: compact ? 40 : 48,
                decoration: BoxDecoration(
                  color: isOpen ? ssOrange : ssOrangeLight,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isOpen ? Icons.photo_camera_outlined : Icons.timer_outlined,
                  color: isOpen ? Colors.white : ssOrange,
                  size: compact ? 21 : 25,
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      obtenerTituloCountdown(window),
                      style: TextStyle(
                        color: isOpen ? ssOrangeDark : ssTitle,
                        fontSize: compact ? 12 : 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      obtenerSubtituloCountdown(window),
                      maxLines: compact ? 1 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isOpen ? ssOrangeDark : ssText2,
                        fontSize: compact ? 11 : 12.5,
                        fontWeight: FontWeight.w500,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 10 : 12,
                  vertical: compact ? 7 : 8,
                ),
                decoration: BoxDecoration(
                  color: isOpen ? ssOrange : ssBg,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: isOpen ? ssOrange : ssBorder),
                ),
                child: Text(
                  formatCountdown(remaining),
                  style: TextStyle(
                    color: isOpen ? Colors.white : ssTitle,
                    fontSize: compact ? 12 : 13,
                    fontWeight: FontWeight.w800,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

String formatSundayCountdownToMidnight(DateTime now) {
  final endOfSunday = DateTime(now.year, now.month, now.day, 23, 59, 59, 999);
  final remaining = endOfSunday.difference(now);

  if (remaining.isNegative) return '0h 00m';

  final hours = remaining.inHours;
  final minutes = remaining.inMinutes.remainder(60);
  return '${hours}h ${minutes.toString().padLeft(2, '0')}m';
}

class SundayBanner extends StatelessWidget {
  const SundayBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<int>(
      stream: Stream.periodic(const Duration(minutes: 1), (value) => value),
      builder: (context, snapshot) {
        final now = DateTime.now();
        final dayNames = [
          'Lunes',
          'Martes',
          'Miércoles',
          'Jueves',
          'Viernes',
          'Sábado',
          'Domingo',
        ];
        final dayName = dayNames[now.weekday - 1];
        final isSunday = now.weekday == DateTime.sunday;
        final daysUntilSunday = isSunday ? 0 : DateTime.sunday - now.weekday;
        final weekLabel = isSunday
            ? obtenerEtiquetaSemana(obtenerWeekKeyActual())
            : '';
        final leftText = isSunday
            ? '¡Sube tu selfie del domingo!'
            : '¡Toca esperar!';
        final rightMain = isSunday
            ? formatSundayCountdownToMidnight(now)
            : '$daysUntilSunday';
        final rightText = daysUntilSunday == 1
            ? 'día hasta el domingo'
            : 'días hasta el domingo';

        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final compact = width < 350;
            final leftBlockWidth = width * (compact ? 0.52 : 0.56);
            final rightBlockWidth = width * (compact ? 0.38 : 0.36);

            return Container(
              height: compact ? 100 : 104,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [ssOrange, Color(0xFFF7C225)],
                ),
                borderRadius: BorderRadius.circular(22),
              ),
              child: Stack(
                children: [
                  Positioned(
                    left: 20,
                    top: 16,
                    child: Text(
                      'HOY ES',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.86),
                        fontSize: compact ? 11 : 12,
                        letterSpacing: 1.2,
                        fontWeight: FontWeight.w600,
                        height: 1,
                      ),
                    ),
                  ),
                  Positioned(
                    right: 22,
                    top: 16,
                    width: rightBlockWidth,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text(
                        weekLabel,
                        maxLines: 1,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.86),
                          fontSize: compact ? 10.8 : 11.6,
                          fontWeight: FontWeight.w700,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 20,
                    top: compact ? 38 : 40,
                    child: Text(
                      dayName,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: compact ? 25 : 26,
                        fontWeight: FontWeight.w800,
                        height: 1,
                      ),
                    ),
                  ),
                  Positioned(
                    right: 22,
                    top: isSunday ? (compact ? 37 : 39) : (compact ? 22 : 24),
                    width: rightBlockWidth,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text(
                        rightMain,
                        textAlign: TextAlign.right,
                        maxLines: 1,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: isSunday
                              ? (compact ? 24 : 26)
                              : (compact ? 50 : 52),
                          fontWeight: FontWeight.w800,
                          height: 1,
                          fontFeatures: isSunday
                              ? const [FontFeature.tabularFigures()]
                              : const [],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 20,
                    bottom: compact ? 17 : 18,
                    width: leftBlockWidth,
                    child: Text(
                      leftText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.94),
                        fontSize: compact ? 12.5 : 13.5,
                        fontWeight: FontWeight.w600,
                        height: 1,
                      ),
                    ),
                  ),
                  if (!isSunday)
                    Positioned(
                      right: 22,
                      bottom: compact ? 17 : 18,
                      width: rightBlockWidth,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Text(
                          rightText,
                          maxLines: 1,
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.92),
                            fontSize: compact ? 12 : 13.2,
                            fontWeight: FontWeight.w600,
                            height: 1,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class SundayCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? margin;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;

  const SundayCard({
    super.key,
    required this.child,
    this.margin,
    this.padding,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(24);
    final shadow = [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.04),
        blurRadius: 14,
        offset: const Offset(0, 4),
      ),
    ];
    final card = Container(
      margin: margin,
      padding: padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ssSurface,
        borderRadius: borderRadius,
        border: Border.all(color: ssBorder),
        boxShadow: shadow,
      ),
      child: child,
    );

    if (onTap == null) return card;

    return Container(
      margin: margin,
      decoration: BoxDecoration(borderRadius: borderRadius, boxShadow: shadow),
      child: Material(
        color: ssSurface,
        borderRadius: borderRadius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Ink(
            padding: padding ?? const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: ssSurface,
              borderRadius: borderRadius,
              border: Border.all(color: ssBorder),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class GroupIcon extends StatelessWidget {
  final String name;
  final String? photoUrl;
  final String? emoji;
  final Object? colorValue;
  final double size;

  const GroupIcon({
    super.key,
    required this.name,
    this.photoUrl,
    this.emoji,
    this.colorValue,
    this.size = 52,
  });

  bool get hasPhoto => photoUrl != null && photoUrl!.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final resolvedColor = groupColorFromValue(colorValue);
    final resolvedEmoji = emoji?.trim().isNotEmpty == true
        ? emoji!.trim()
        : extractLastEmoji(name) ?? fallbackGroupEmoji(name);
    final radius = size * 0.34;

    if (hasPhoto) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(radius)),
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: ssOrangeMid, width: 2),
        ),
        clipBehavior: Clip.antiAlias,
        child: CachedRemoteImage(
          imageUrl: photoUrl!.trim(),
          cacheVariant: 'avatar',
          width: size,
          height: size,
          fit: BoxFit.cover,
          alignment: Alignment.center,
          filterQuality: FilterQuality.high,
          loadingWidget: _GroupIconFallback(
            name: name,
            emoji: resolvedEmoji,
            color: resolvedColor,
            size: size,
          ),
          errorWidget: _GroupIconFallback(
            name: name,
            emoji: resolvedEmoji,
            color: resolvedColor,
            size: size,
          ),
        ),
      );
    }

    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: resolvedColor.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: ssOrangeMid, width: 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: _GroupIconFallback(
        name: name,
        emoji: resolvedEmoji,
        color: resolvedColor,
        size: size,
      ),
    );
  }
}

class _GroupIconFallback extends StatelessWidget {
  final String name;
  final String? emoji;
  final Color color;
  final double size;

  const _GroupIconFallback({
    required this.name,
    required this.emoji,
    required this.color,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final hasEmoji = emoji != null && emoji!.trim().isNotEmpty;

    return Center(
      child: Text(
        hasEmoji ? emoji! : initialsFromName(name),
        style: TextStyle(
          color: hasEmoji ? ssText : color,
          fontSize: hasEmoji ? size * 0.42 : size * 0.34,
          fontWeight: FontWeight.w900,
          height: 1,
        ),
      ),
    );
  }
}

class MiniProfileAvatar extends StatelessWidget {
  final String name;
  final String? photoUrl;
  final double size;
  final Color? borderColor;

  const MiniProfileAvatar({
    super.key,
    required this.name,
    required this.photoUrl,
    this.size = 30,
    this.borderColor,
  });

  bool get hasPhoto => photoUrl != null && photoUrl!.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: ssOrange,
        shape: BoxShape.circle,
        border: borderColor == null
            ? null
            : Border.all(color: borderColor!, width: 1.6),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: ClipOval(
        child: Container(
          color: ssOrange,
          child: hasPhoto
              ? Stack(
                  fit: StackFit.expand,
                  children: [
                    CachedRemoteImage(
                      imageUrl: photoUrl!.trim(),
                      cacheVariant: 'avatar',
                      fit: BoxFit.cover,
                      alignment: Alignment.center,
                      filterQuality: FilterQuality.high,
                      loadingWidget: _MiniAvatarInitials(
                        name: name,
                        size: size,
                      ),
                      errorWidget: _MiniAvatarInitials(name: name, size: size),
                    ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: ssOrange.withValues(alpha: 0.14),
                        backgroundBlendMode: BlendMode.softLight,
                      ),
                    ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: const Alignment(-0.45, -0.55),
                          radius: 1.2,
                          colors: [
                            Colors.white.withValues(alpha: 0.08),
                            Colors.transparent,
                            ssOrangeDark.withValues(alpha: 0.18),
                          ],
                          stops: const [0, 0.58, 1],
                        ),
                      ),
                    ),
                  ],
                )
              : _MiniAvatarInitials(name: name, size: size),
        ),
      ),
    );
  }
}

class _MiniAvatarInitials extends StatelessWidget {
  final String name;
  final double size;

  const _MiniAvatarInitials({required this.name, required this.size});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        initialsFromName(name),
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.32,
          fontWeight: FontWeight.w900,
          height: 1,
        ),
      ),
    );
  }
}

class GroupMembersAvatarStrip extends StatelessWidget {
  final String groupId;
  final int memberCount;

  const GroupMembersAvatarStrip({
    super.key,
    required this.groupId,
    required this.memberCount,
  });

  @override
  Widget build(BuildContext context) {
    final membersRef = FirebaseFirestore.instance
        .collection('groups')
        .doc(groupId)
        .collection('members')
        .orderBy('joinedAt')
        .limit(4);

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: membersRef.snapshots(),
      builder: (context, snapshot) {
        final members = snapshot.data?.docs ?? [];
        final shown = members.length;
        final remaining = (memberCount - shown).clamp(0, 999);

        if (snapshot.connectionState == ConnectionState.waiting &&
            members.isEmpty) {
          return const SizedBox(height: 30);
        }

        return Row(
          children: [
            ...members.map((member) {
              final data = member.data();
              final name = formatUserDisplayName(
                data['effectiveName'] ?? 'Usuario',
              );
              final rawPhotoUrl = data['effectivePhotoUrl'];
              final photoUrl = rawPhotoUrl is String ? rawPhotoUrl : null;
              return Padding(
                padding: const EdgeInsets.only(right: 5),
                child: ResolvedMemberMiniAvatar(
                  uid: member.id,
                  name: name,
                  photoUrl: photoUrl,
                ),
              );
            }),
            if (remaining > 0)
              MiniAvatar(text: '+$remaining', bg: ssSeparator, fg: ssText3),
          ],
        );
      },
    );
  }
}

class ResolvedMemberMiniAvatar extends StatelessWidget {
  final String uid;
  final String name;
  final String? photoUrl;

  const ResolvedMemberMiniAvatar({
    super.key,
    required this.uid,
    required this.name,
    required this.photoUrl,
  });

  bool get hasMemberPhoto => photoUrl != null && photoUrl!.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    if (hasMemberPhoto) {
      return MiniProfileAvatar(name: name, photoUrl: photoUrl, size: 30);
    }

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .snapshots(),
      builder: (context, snapshot) {
        final userData = snapshot.data?.data();
        final rawUserPhotoUrl = userData?['basePhotoUrl'];
        final resolvedPhotoUrl = rawUserPhotoUrl is String
            ? rawUserPhotoUrl
            : null;
        final rawUserName = userData?['baseName'];
        final resolvedName =
            rawUserName is String && rawUserName.trim().isNotEmpty
            ? rawUserName.trim()
            : name;

        return MiniProfileAvatar(
          name: resolvedName,
          photoUrl: resolvedPhotoUrl,
          size: 30,
        );
      },
    );
  }
}

class GroupStreakMedal extends StatelessWidget {
  final String groupId;

  const GroupStreakMedal({super.key, required this.groupId});

  void _openStats(BuildContext context, GroupStreakStats stats) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => GroupStreakStatsSheet(stats: stats),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<GroupStreakStats>(
      future: calcularEstadisticasRachaCompletaGrupoFirestore(groupId: groupId),
      builder: (context, snapshot) {
        final stats = snapshot.data ?? GroupStreakStats.zero;
        final medalCount = stats.current;

        if (medalCount <= 0) {
          return const SizedBox.shrink();
        }

        return GestureDetector(
          onTap: () => _openStats(context, stats),
          child: Semantics(
            button: true,
            label: medalCount == 1
                ? 'El grupo lleva 1 semana completa seguida'
                : 'El grupo lleva $medalCount semanas completas seguidas',
            child: SundayStreakMedalIcon(count: medalCount),
          ),
        );
      },
    );
  }
}

class SundayStreakMedalIcon extends StatelessWidget {
  final int count;

  const SundayStreakMedalIcon({super.key, required this.count});

  @override
  Widget build(BuildContext context) {
    final label = '$count';

    Widget ribbon({required bool left}) {
      return Transform.rotate(
        angle: left ? -0.18 : 0.18,
        child: Container(
          width: 7,
          height: 24,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: left
                  ? const [ssOrangeDark, ssOrange]
                  : const [Color(0xFFFFD9A5), ssOrangeMid],
            ),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: ssBg, width: 0.9),
          ),
        ),
      );
    }

    return SizedBox(
      width: 34,
      height: 40,
      child: Stack(
        alignment: Alignment.topCenter,
        clipBehavior: Clip.none,
        children: [
          Positioned(
            top: 0,
            child: SizedBox(
              width: 28,
              height: 27,
              child: Stack(
                alignment: Alignment.topCenter,
                clipBehavior: Clip.none,
                children: [
                  Positioned(left: 6, top: 0, child: ribbon(left: true)),
                  Positioned(right: 6, top: 0, child: ribbon(left: false)),
                  Positioned(
                    top: 3,
                    child: Container(
                      width: 4,
                      height: 20,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.48),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            top: 13,
            child: Container(
              width: 27,
              height: 27,
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: ssBg,
                shape: BoxShape.circle,
                border: Border.all(color: ssOrangeMid, width: 1.3),
                boxShadow: [
                  BoxShadow(
                    color: ssOrangeDark.withValues(alpha: 0.16),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFFFFC978), ssOrange, ssOrangeDark],
                  ),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Positioned(
                      top: 5,
                      left: 7,
                      child: Container(
                        width: 8,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.36),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3.5),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          label,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w900,
                            height: 1,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class GroupStreakStatsSheet extends StatelessWidget {
  final GroupStreakStats stats;

  const GroupStreakStatsSheet({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    final currentText = stats.current == 1
        ? '1 semana seguida'
        : '${stats.current} semanas seguidas';
    final recordText = stats.record == 1
        ? '1 semana'
        : '${stats.record} semanas';

    return SafeArea(
      top: false,
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.72,
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 38,
              height: 4,
              margin: const EdgeInsets.only(bottom: 18),
              decoration: BoxDecoration(
                color: ssBorder,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            SundayStreakMedalIcon(count: stats.current),
            const SizedBox(height: 18),
            Text(
              'Racha del grupo',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: ssTitle,
                fontSize: 20,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Cuenta las semanas seguidas en las que todos los miembros han subido su Sunday Selfie.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: ssText2,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 18),
            GroupStreakStatRow(
              icon: Icons.local_fire_department_rounded,
              label: 'Actual',
              value: currentText,
            ),
            const SizedBox(height: 10),
            GroupStreakStatRow(
              icon: Icons.workspace_premium_rounded,
              label: 'Record',
              value: recordText,
            ),
          ],
        ),
      ),
    );
  }
}

class GroupStreakStatRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const GroupStreakStatRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: ssBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ssBorder),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: ssOrangeLight,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: ssOrangeDark, size: 19),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: ssText2,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: ssTitle,
              fontSize: 15,
              fontWeight: FontWeight.w900,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class MiniAvatar extends StatelessWidget {
  final String text;
  final Color bg;
  final Color fg;

  const MiniAvatar({
    super.key,
    required this.text,
    this.bg = ssOrange,
    this.fg = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        gradient: bg == ssOrange
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xDDF4A261), Color(0x99F4A261)],
              )
            : null,
      ),
      child: Text(
        text,
        style: TextStyle(color: fg, fontSize: 9.5, fontWeight: FontWeight.w800),
      ),
    );
  }
}

enum SundayButtonVariant { primary, secondary, outline, ghost }

class SundayButton extends StatelessWidget {
  final String text;
  final VoidCallback? onPressed;
  final SundayButtonVariant variant;

  const SundayButton({
    super.key,
    required this.text,
    required this.onPressed,
    this.variant = SundayButtonVariant.primary,
  });

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color fg;
    BorderSide side = BorderSide.none;

    switch (variant) {
      case SundayButtonVariant.primary:
        bg = ssOrange;
        fg = Colors.white;
        break;
      case SundayButtonVariant.secondary:
        bg = ssOrangeLight;
        fg = ssOrange;
        break;
      case SundayButtonVariant.outline:
        bg = Colors.white;
        fg = ssText;
        side = const BorderSide(color: ssBorder, width: 1.5);
        break;
      case SundayButtonVariant.ghost:
        bg = Colors.transparent;
        fg = ssText2;
        break;
    }

    return SizedBox(
      width: double.infinity,
      height: 48,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: bg,
          foregroundColor: fg,
          elevation: 0,
          disabledBackgroundColor: bg.withValues(alpha: 0.4),
          disabledForegroundColor: fg.withValues(alpha: 0.6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: side,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20),
        ),
        onPressed: onPressed,
        child: Text(
          text,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class SundayActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const SundayActionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(18);

    return Material(
      color: Colors.transparent,
      borderRadius: borderRadius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: ssBg,
            borderRadius: borderRadius,
            border: Border.all(color: ssBorder, width: 1.4),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: ssOrangeLight,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: ssOrange, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: ssTitle,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.35,
                        color: ssText2,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right_rounded, color: ssText3, size: 24),
            ],
          ),
        ),
      ),
    );
  }
}

class SundayInput extends StatelessWidget {
  final TextEditingController controller;
  final String hintText;

  const SundayInput({
    super.key,
    required this.controller,
    required this.hintText,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      style: const TextStyle(fontSize: 16, color: ssText),
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: const TextStyle(color: ssText3),
        filled: true,
        fillColor: ssBg,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 13,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: ssBorder, width: 1.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: ssBorder, width: 1.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: ssOrange, width: 1.5),
        ),
      ),
    );
  }
}

class SmallPillButton extends StatelessWidget {
  final String text;
  final VoidCallback onTap;

  const SmallPillButton({super.key, required this.text, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(999);

    return Material(
      color: Colors.transparent,
      borderRadius: borderRadius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Ink(
          height: 25,
          padding: const EdgeInsets.symmetric(horizontal: 15),
          decoration: BoxDecoration(
            color: ssOrange,
            borderRadius: borderRadius,
          ),
          child: Center(
            child: Text(
              text,
              maxLines: 1,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w800,
                height: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class WeekCalendarEntry {
  final String weekKey;
  final int isoYear;
  final int isoWeek;
  final int postedCount;
  final int memberCount;
  final DateTime sunday;

  const WeekCalendarEntry({
    required this.weekKey,
    required this.isoYear,
    required this.isoWeek,
    required this.postedCount,
    required this.memberCount,
    required this.sunday,
  });

  int get totalCount => memberCount <= 0 ? postedCount : memberCount;

  bool get isComplete => totalCount > 0 && postedCount >= totalCount;

  String get progressLabel => '$postedCount/$totalCount';

  String get monthLabel => monthName(sunday.month);
}

List<WeekCalendarEntry> construirEntradasCalendarioSemanas({
  required Iterable<String> weekKeys,
  required List<QueryDocumentSnapshot<Map<String, dynamic>>> weekDocs,
  required int memberCount,
}) {
  final weekDocsById = {for (final doc in weekDocs) doc.id: doc};
  final entries = <WeekCalendarEntry>[];

  for (final weekKey in weekKeys) {
    final parts = weekKey.split('-W');
    if (parts.length != 2) continue;

    final isoYear = int.tryParse(parts[0]);
    final isoWeek = int.tryParse(parts[1]);
    final sunday = domingoDesdeWeekKey(weekKey);

    if (isoYear == null || isoWeek == null || sunday == null) continue;

    final weekData = weekDocsById[weekKey]?.data();
    final rawPostCount = weekData?['postCount'] ?? 0;
    final postCount = rawPostCount is int
        ? rawPostCount
        : int.tryParse('$rawPostCount') ?? 0;

    entries.add(
      WeekCalendarEntry(
        weekKey: weekKey,
        isoYear: isoYear,
        isoWeek: isoWeek,
        postedCount: postCount,
        memberCount: memberCount,
        sunday: sunday,
      ),
    );
  }

  return entries;
}

Future<String?> showWeekCalendarSheet({
  required BuildContext context,
  required List<WeekCalendarEntry> entries,
  required String selectedWeekKey,
}) {
  if (entries.isEmpty) return Future.value();

  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    enableDrag: true,
    backgroundColor: Colors.transparent,
    builder: (_) =>
        WeekCalendarSheet(entries: entries, selectedWeekKey: selectedWeekKey),
  );
}

Future<List<String>?> showDownloadWeeksSheet({
  required BuildContext context,
  required List<WeekCalendarEntry> entries,
}) {
  if (entries.isEmpty) {
    showSundaySnack(context, 'No hay semanas para descargar');
    return Future.value();
  }

  return showModalBottomSheet<List<String>>(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    enableDrag: true,
    backgroundColor: Colors.transparent,
    builder: (_) => DownloadWeeksSheet(entries: entries),
  );
}

class DownloadWeeksSheet extends StatefulWidget {
  final List<WeekCalendarEntry> entries;

  const DownloadWeeksSheet({super.key, required this.entries});

  @override
  State<DownloadWeeksSheet> createState() => _DownloadWeeksSheetState();
}

class _DownloadWeeksSheetState extends State<DownloadWeeksSheet> {
  late int selectedYear;
  late Set<String> selectedWeekKeys;

  @override
  void initState() {
    super.initState();
    selectedYear = widget.entries.first.isoYear;
    selectedWeekKeys = {};
  }

  Map<int, List<WeekCalendarEntry>> get entriesByYear {
    final grouped = <int, List<WeekCalendarEntry>>{};
    for (final entry in widget.entries) {
      grouped.putIfAbsent(entry.isoYear, () => []).add(entry);
    }
    return grouped;
  }

  void _toggleWeek(WeekCalendarEntry entry) {
    if (entry.postedCount <= 0) return;
    setState(() {
      if (!selectedWeekKeys.remove(entry.weekKey)) {
        selectedWeekKeys.add(entry.weekKey);
      }
    });
  }

  int _availableWeekCount(Iterable<WeekCalendarEntry> entries) {
    return entries.where((entry) => entry.postedCount > 0).length;
  }

  int _selectedWeekCount(Iterable<WeekCalendarEntry> entries) {
    return entries
        .where((entry) => selectedWeekKeys.contains(entry.weekKey))
        .length;
  }

  int get _selectedPhotoCount {
    var count = 0;
    for (final entry in widget.entries) {
      if (selectedWeekKeys.contains(entry.weekKey)) {
        count += entry.postedCount;
      }
    }
    return count;
  }

  String _yearSubtitle({
    required List<WeekCalendarEntry> yearEntries,
    required bool selected,
  }) {
    final selectedCount = _selectedWeekCount(yearEntries);
    if (selected && selectedCount > 0) {
      return selectedCount == 1
          ? '1 seleccionada'
          : '$selectedCount seleccionadas';
    }

    final availableCount = _availableWeekCount(yearEntries);
    return availableCount == 1 ? '1 semana' : '$availableCount semanas';
  }

  void _selectVisibleYear(List<WeekCalendarEntry> yearEntries) {
    setState(() {
      for (final entry in yearEntries) {
        if (entry.postedCount > 0) selectedWeekKeys.add(entry.weekKey);
      }
    });
  }

  void _downloadSelectedWeeks() {
    Navigator.pop(context, ordenarWeekKeysDescendentes(selectedWeekKeys));
  }

  @override
  Widget build(BuildContext context) {
    final groupedEntries = entriesByYear;
    final years = groupedEntries.keys.toList()..sort((a, b) => b.compareTo(a));
    final activeYear = years.contains(selectedYear)
        ? selectedYear
        : years.first;
    final yearEntries = groupedEntries[activeYear] ?? const [];
    final selectedCount = selectedWeekKeys.length;
    final selectedPhotoCount = _selectedPhotoCount;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final maxSheetHeight = math.min(screenHeight * 0.91, 780.0);
    final minSheetHeight = math.min(maxSheetHeight, screenHeight * 0.72);

    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.12,
      child: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            constraints: BoxConstraints(
              minHeight: minSheetHeight,
              maxHeight: maxSheetHeight,
            ),
            decoration: const BoxDecoration(
              color: ssBg,
              borderRadius: BorderRadius.vertical(top: Radius.circular(36)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 48,
                    height: 6,
                    margin: const EdgeInsets.only(top: 12, bottom: 22),
                    decoration: BoxDecoration(
                      color: ssBorder,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 0, 18, 0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Descargar selfies',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: ssTitle,
                                fontSize: 30,
                                fontWeight: FontWeight.w900,
                                height: 1.05,
                              ),
                            ),
                            SizedBox(height: 8),
                            Text(
                              'Elige el año y las semanas a guardar',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: ssText2,
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                height: 1.12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Material(
                        color: ssSeparator,
                        shape: const CircleBorder(),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => Navigator.pop(context),
                          child: const SizedBox(
                            width: 54,
                            height: 54,
                            child: Icon(
                              Icons.close_rounded,
                              color: ssText2,
                              size: 31,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 28),
                SizedBox(
                  height: 88,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final visibleCards = math.min(years.length, 3);
                      final fittedWidth = visibleCards == 0
                          ? 112.0
                          : (constraints.maxWidth -
                                    56 -
                                    ((visibleCards - 1) * 12)) /
                                visibleCards;
                      final cardWidth = math.max(104.0, fittedWidth);

                      return ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 28),
                        itemCount: years.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 12),
                        itemBuilder: (context, index) {
                          final year = years[index];
                          final selected = year == activeYear;
                          final yearEntries = groupedEntries[year] ?? const [];

                          return DownloadYearCard(
                            width: cardWidth,
                            year: year,
                            subtitle: _yearSubtitle(
                              yearEntries: yearEntries,
                              selected: selected,
                            ),
                            selected: selected,
                            onTap: () => setState(() => selectedYear = year),
                          );
                        },
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 30, 28, 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '$activeYear · SEMANAS',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: ssText3,
                            fontSize: 17,
                            fontWeight: FontWeight.w900,
                            height: 1,
                            letterSpacing: 0,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _availableWeekCount(yearEntries) == 0
                              ? null
                              : () => _selectVisibleYear(yearEntries),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerRight,
                              child: Text(
                                'Seleccionar todas',
                                maxLines: 1,
                                style: TextStyle(
                                  color: _availableWeekCount(yearEntries) == 0
                                      ? ssText3
                                      : ssOrangeDark,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w900,
                                  height: 1,
                                  letterSpacing: 0,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: GridView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(28, 0, 28, 22),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          childAspectRatio: 0.92,
                        ),
                    itemCount: yearEntries.length,
                    itemBuilder: (context, index) {
                      final entry = yearEntries[index];
                      return DownloadWeekTile(
                        entry: entry,
                        selected: selectedWeekKeys.contains(entry.weekKey),
                        onTap: () => _toggleWeek(entry),
                      );
                    },
                  ),
                ),
                Container(
                  padding: const EdgeInsets.fromLTRB(28, 16, 28, 18),
                  decoration: const BoxDecoration(
                    color: ssBg,
                    border: Border(top: BorderSide(color: ssSeparator)),
                  ),
                  child: DownloadWeeksBottomButton(
                    selectedWeekCount: selectedCount,
                    selectedPhotoCount: selectedPhotoCount,
                    onPressed: selectedCount == 0
                        ? null
                        : _downloadSelectedWeeks,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class DownloadYearCard extends StatelessWidget {
  final double width;
  final int year;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const DownloadYearCard({
    super.key,
    required this.width,
    required this.year,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = selected ? Colors.white : ssTitle;
    final muted = selected ? Colors.white : ssText3;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(22),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Ink(
          width: width,
          decoration: BoxDecoration(
            color: selected ? ssOrange : Colors.white,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: selected ? ssOrange : ssBorder,
              width: 1.5,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: ssOrange.withValues(alpha: 0.18),
                      blurRadius: 24,
                      offset: const Offset(0, 12),
                    ),
                  ]
                : null,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '$year',
                    maxLines: 1,
                    style: TextStyle(
                      color: fg,
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      height: 0.95,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 9),
                  Text(
                    subtitle,
                    maxLines: 1,
                    style: TextStyle(
                      color: muted,
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                      height: 1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class DownloadWeeksBottomButton extends StatelessWidget {
  final int selectedWeekCount;
  final int selectedPhotoCount;
  final VoidCallback? onPressed;

  const DownloadWeeksBottomButton({
    super.key,
    required this.selectedWeekCount,
    required this.selectedPhotoCount,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final weekLabel = selectedWeekCount == 1 ? 'semana' : 'semanas';
    final photoLabel = selectedPhotoCount == 1 ? 'foto' : 'fotos';
    final text = enabled
        ? 'Descargar $selectedWeekCount $weekLabel · $selectedPhotoCount $photoLabel'
        : 'Selecciona semanas';

    return Material(
      color: enabled ? ssOrange : ssSeparator,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox(
          height: 64,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.download_rounded,
                      color: enabled ? Colors.white : ssText3,
                      size: 29,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      text,
                      maxLines: 1,
                      style: TextStyle(
                        color: enabled ? Colors.white : ssText3,
                        fontSize: 19,
                        fontWeight: FontWeight.w900,
                        height: 1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class DownloadWeekTile extends StatelessWidget {
  final WeekCalendarEntry entry;
  final bool selected;
  final VoidCallback onTap;

  const DownloadWeekTile({
    super.key,
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = entry.postedCount > 0;
    final bg = selected ? ssOrangeLight : Colors.white;
    final borderColor = selected ? ssOrange : ssBorder;
    final accentColor = selected ? ssOrangeDark : ssTitle;
    final secondaryColor = selected ? ssOrangeDark : ssText3;

    return Opacity(
      opacity: enabled ? 1 : 0.42,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(22),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: Ink(
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: borderColor,
                width: selected ? 2.5 : 1.4,
              ),
            ),
            child: Stack(
              children: [
                Positioned(
                  top: 12,
                  right: 12,
                  child: _DownloadWeekSelectionDot(selected: selected),
                ),
                Center(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 14, 8, 10),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'SEM',
                            maxLines: 1,
                            style: TextStyle(
                              color: secondaryColor,
                              fontSize: 14,
                              fontWeight: FontWeight.w900,
                              height: 1,
                              letterSpacing: 0,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '${entry.isoWeek}',
                            maxLines: 1,
                            style: TextStyle(
                              color: accentColor,
                              fontSize: 38,
                              fontWeight: FontWeight.w900,
                              height: 0.9,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            entry.progressLabel,
                            maxLines: 1,
                            style: TextStyle(
                              color: secondaryColor,
                              fontSize: 14,
                              fontWeight: FontWeight.w900,
                              height: 1,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            entry.monthLabel,
                            maxLines: 1,
                            style: TextStyle(
                              color: secondaryColor,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              height: 1,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DownloadWeekSelectionDot extends StatelessWidget {
  final bool selected;

  const _DownloadWeekSelectionDot({required this.selected});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: selected ? ssOrange : Colors.white,
        shape: BoxShape.circle,
        border: selected ? null : Border.all(color: ssBorder, width: 1.6),
      ),
      child: selected
          ? const Icon(Icons.check_rounded, color: Colors.white, size: 20)
          : null,
    );
  }
}

class WeekCalendarButton extends StatelessWidget {
  final VoidCallback? onTap;

  const WeekCalendarButton({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(999);

    return Tooltip(
      message: 'Ir a una semana',
      child: Material(
        color: Colors.transparent,
        borderRadius: borderRadius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Ink(
            width: 34,
            height: 25,
            decoration: BoxDecoration(
              color: onTap == null ? ssSeparator : ssOrangeLight,
              borderRadius: borderRadius,
              border: Border.all(
                color: onTap == null ? ssBorder : ssOrangeMid,
                width: 1.2,
              ),
            ),
            child: Icon(
              Icons.calendar_month_outlined,
              color: onTap == null ? ssText3 : ssOrangeDark,
              size: 17,
            ),
          ),
        ),
      ),
    );
  }
}

class WeekCalendarSheet extends StatefulWidget {
  final List<WeekCalendarEntry> entries;
  final String selectedWeekKey;

  const WeekCalendarSheet({
    super.key,
    required this.entries,
    required this.selectedWeekKey,
  });

  @override
  State<WeekCalendarSheet> createState() => _WeekCalendarSheetState();
}

class _WeekCalendarSheetState extends State<WeekCalendarSheet> {
  late int selectedYear;

  @override
  void initState() {
    super.initState();

    final selectedEntry = widget.entries
        .where((entry) => entry.weekKey == widget.selectedWeekKey)
        .firstOrNull;

    selectedYear = selectedEntry?.isoYear ?? widget.entries.first.isoYear;
  }

  Map<int, List<WeekCalendarEntry>> get entriesByYear {
    final grouped = <int, List<WeekCalendarEntry>>{};

    for (final entry in widget.entries) {
      grouped.putIfAbsent(entry.isoYear, () => []).add(entry);
    }

    return grouped;
  }

  @override
  Widget build(BuildContext context) {
    SundayClockScope.watch(context);
    final groupedEntries = entriesByYear;
    final years = groupedEntries.keys.toList()..sort((a, b) => b.compareTo(a));
    final activeYear = years.contains(selectedYear)
        ? selectedYear
        : years.first;
    final yearEntries = groupedEntries[activeYear] ?? const [];
    final screenHeight = MediaQuery.sizeOf(context).height;
    final maxSheetHeight = math.min(screenHeight * 0.86, 680.0);
    final minSheetHeight = math.min(screenHeight * 0.34, 320.0);

    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.12,
      child: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            constraints: BoxConstraints(
              minHeight: minSheetHeight,
              maxHeight: maxSheetHeight,
            ),
            decoration: const BoxDecoration(
              color: ssBg,
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 38,
                  height: 4,
                  margin: const EdgeInsets.only(top: 10, bottom: 12),
                  decoration: BoxDecoration(
                    color: ssBorder,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                SizedBox(
                  height: 62,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    itemCount: years.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 9),
                    itemBuilder: (context, index) {
                      final year = years[index];
                      final selected = year == activeYear;
                      final count = groupedEntries[year]?.length ?? 0;

                      return WeekCalendarYearCard(
                        year: year,
                        weekCount: count,
                        selected: selected,
                        onTap: () => setState(() => selectedYear = year),
                      );
                    },
                  ),
                ),
                Flexible(
                  fit: FlexFit.loose,
                  child: CustomScrollView(
                    shrinkWrap: true,
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
                        sliver: SliverToBoxAdapter(
                          child: Text(
                            '$activeYear · SEMANAS',
                            style: const TextStyle(
                              color: ssText3,
                              fontSize: 14,
                              fontWeight: FontWeight.w900,
                              height: 1,
                            ),
                          ),
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                        sliver: SliverGrid(
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 4,
                                mainAxisSpacing: 9,
                                crossAxisSpacing: 9,
                                childAspectRatio: 0.84,
                              ),
                          delegate: SliverChildBuilderDelegate((
                            context,
                            index,
                          ) {
                            final entry = yearEntries[index];

                            return WeekCalendarWeekTile(
                              entry: entry,
                              selected: entry.weekKey == widget.selectedWeekKey,
                              onTap: () =>
                                  Navigator.pop(context, entry.weekKey),
                            );
                          }, childCount: yearEntries.length),
                        ),
                      ),
                    ],
                  ),
                ),
                const WeekCalendarLegend(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class WeekCalendarYearCard extends StatelessWidget {
  final int year;
  final int weekCount;
  final bool selected;
  final VoidCallback onTap;

  const WeekCalendarYearCard({
    super.key,
    required this.year,
    required this.weekCount,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = selected ? Colors.white : ssTitle;
    final muted = selected ? Colors.white : ssText3;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Ink(
          width: 96,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? ssOrange : Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? ssOrange : ssBorder,
              width: 1.4,
            ),
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '$year',
                  maxLines: 1,
                  style: TextStyle(
                    color: fg,
                    fontSize: 21,
                    fontWeight: FontWeight.w900,
                    height: 1,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  weekCount == 1 ? '1 semana' : '$weekCount semanas',
                  maxLines: 1,
                  style: TextStyle(
                    color: muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    height: 1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class WeekCalendarWeekTile extends StatelessWidget {
  final WeekCalendarEntry entry;
  final bool selected;
  final VoidCallback onTap;

  const WeekCalendarWeekTile({
    super.key,
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final complete = entry.isComplete;
    final bg = complete ? ssOrangeLight : Colors.white;
    final borderColor = selected ? ssOrange : ssBorder;
    final borderWidth = selected ? 2.0 : 1.4;
    const labelColor = ssText3;
    const mainColor = ssTitle;
    const secondaryColor = ssText3;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderColor, width: borderWidth),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 6),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'SEM',
                    maxLines: 1,
                    style: TextStyle(
                      color: labelColor,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w900,
                      height: 1,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${entry.isoWeek}',
                    maxLines: 1,
                    style: TextStyle(
                      color: mainColor,
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                      height: 0.95,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    entry.progressLabel,
                    maxLines: 1,
                    style: TextStyle(
                      color: secondaryColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      height: 1,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    entry.monthLabel,
                    maxLines: 1,
                    style: TextStyle(
                      color: secondaryColor,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w500,
                      height: 1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class WeekCalendarLegend extends StatelessWidget {
  const WeekCalendarLegend({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
      decoration: const BoxDecoration(
        color: ssBg,
        border: Border(top: BorderSide(color: ssSeparator, width: 1.2)),
      ),
      child: const Wrap(
        alignment: WrapAlignment.center,
        spacing: 16,
        runSpacing: 8,
        children: [
          WeekCalendarLegendItem(
            color: ssOrangeLight,
            borderColor: ssBorder,
            label: 'Completa',
          ),
          WeekCalendarLegendItem(
            color: Colors.white,
            borderColor: ssBorder,
            label: 'Incompleta',
          ),
        ],
      ),
    );
  }
}

class WeekCalendarLegendItem extends StatelessWidget {
  final Color color;
  final Color? borderColor;
  final String label;

  const WeekCalendarLegendItem({
    super.key,
    required this.color,
    required this.label,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 13,
          height: 13,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: borderColor == null
                ? null
                : Border.all(color: borderColor!, width: 1.4),
          ),
        ),
        const SizedBox(width: 6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 92),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: ssText2,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              height: 1,
            ),
          ),
        ),
      ],
    );
  }
}

class WeekChip extends StatelessWidget {
  final String text;
  final bool selected;
  final VoidCallback onTap;
  final double horizontalPadding;

  const WeekChip({
    super.key,
    required this.text,
    required this.selected,
    required this.onTap,
    this.horizontalPadding = 13,
  });

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(999);

    return Material(
      color: Colors.transparent,
      borderRadius: borderRadius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Ink(
          height: 25,
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          decoration: BoxDecoration(
            color: selected ? ssOrangeChip : Colors.white,
            borderRadius: borderRadius,
            border: selected ? null : Border.all(color: ssBorder, width: 1.2),
          ),
          child: Center(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? Colors.white : ssText2,
                fontSize: 13,
                fontWeight: FontWeight.w800,
                height: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class WeekYearSeparatorChip extends StatelessWidget {
  final String year;

  const WeekYearSeparatorChip({super.key, required this.year});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 25,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: ssSeparator,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: ssBorder, width: 1.1),
      ),
      child: Text(
        year,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: ssText3,
          fontSize: 12,
          fontWeight: FontWeight.w900,
          height: 1,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class EmptyGroupsCard extends StatelessWidget {
  final VoidCallback onTap;

  const EmptyGroupsCard({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SundayCard(
      onTap: onTap,
      margin: const EdgeInsets.only(bottom: 12),
      child: const EmptyStateContent(
        icon: Icons.groups_outlined,
        title: 'Todavía no tienes grupos',
        subtitle: 'Crea uno o únete con un código de invitación',
      ),
    );
  }
}

class InviteHintCard extends StatelessWidget {
  final VoidCallback onTap;

  const InviteHintCard({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(16);

    return Material(
      color: Colors.transparent,
      borderRadius: borderRadius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 80),
          child: Ink(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: ssOrangeLight,
              border: Border.all(
                color: ssOrangeMid,
                width: 1.5,
                style: BorderStyle.solid,
              ),
              borderRadius: borderRadius,
            ),
            child: const Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '¿Tienes un grupo en mente?',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: ssOrangeDark,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Crea uno o únete con un código de invitación',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: ssText2, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class CircleIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool dark;

  const CircleIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.dark = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: dark
                  ? Colors.white.withValues(alpha: 0.16)
                  : Colors.white.withValues(alpha: 0.70),
              shape: BoxShape.circle,
              border: Border.all(
                color: dark
                    ? Colors.white.withValues(alpha: 0.15)
                    : Colors.black.withValues(alpha: 0.06),
              ),
            ),
            child: Icon(icon, color: dark ? Colors.white : ssText, size: 26),
          ),
        ),
      ),
    );
  }
}

class WeekCalendarGraphic extends StatelessWidget {
  const WeekCalendarGraphic({super.key});

  @override
  Widget build(BuildContext context) {
    final days = ['L', 'M', 'X', 'J', 'V', 'S', 'D'];
    final todayIndex = DateTime.now().weekday - 1;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(days.length, (index) {
        final isSunday = index == 6;
        final isToday = index == todayIndex;
        final isPastOrToday = index <= todayIndex;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Column(
            children: [
              Text(
                days[index],
                style: TextStyle(
                  color: isSunday || isPastOrToday ? ssOrange : ssText3,
                  fontSize: 10,
                  fontWeight: isSunday || isToday
                      ? FontWeight.w800
                      : FontWeight.w500,
                ),
              ),
              const SizedBox(height: 4),
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isSunday
                      ? ssBg
                      : isPastOrToday
                      ? ssOrangeLight
                      : ssSeparator,
                  borderRadius: BorderRadius.circular(8),
                  border: isSunday
                      ? Border.all(color: ssOrangeMid, width: 1.1)
                      : null,
                ),
                child: isSunday
                    ? const SundaySelfieLogoMark(size: 18)
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        );
      }),
    );
  }
}

String weekBadgeText(String weekKey) {
  final parts = weekKey.split('-W');
  if (parts.length != 2) return weekKey;
  final week = int.tryParse(parts[1]) ?? 0;
  return week > 0 ? 'Sem $week · ${parts[0]}' : weekKey;
}

String? fallbackGroupEmoji(String name) {
  final lower = cleanGroupDisplayName(name).toLowerCase();

  if (lower.contains('familia')) return '🏠';
  if (lower.contains('pandilla') || lower.contains('amigo')) return '🌞';
  if (lower.contains('trabajo') || lower.contains('curro')) return '💼';
  if (lower.contains('uni') || lower.contains('clase')) return '🎓';
  if (lower.contains('viaje') || lower.contains('nyc')) return '✈️';

  return null;
}

String formatUserDisplayName(dynamic value) {
  final raw = value?.toString().trim() ?? '';
  final clean = raw.isEmpty ? 'Usuario' : raw;
  final first = clean.characters.first.toUpperCase();
  final rest = clean.characters.skip(1).join();
  return '$first$rest';
}

String formatMemberCount(int count) {
  return count == 1 ? '1 miembro' : '$count miembros';
}

String formatActiveWeeksLabel(int count) {
  return count == 1 ? '1 semana activo' : '$count semanas activo';
}

String formatGroupDisplayName(String name) {
  final clean = cleanGroupDisplayName(name);
  if (clean.isEmpty) return 'Grupo';
  final first = clean.characters.first.toUpperCase();
  final rest = clean.characters.skip(1).join();
  return '$first$rest';
}

String cleanGroupDisplayName(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return 'Grupo';
  final emoji = extractLastEmoji(trimmed);
  if (emoji == null) return trimmed;
  return trimmed.substring(0, trimmed.length - emoji.length).trim().isEmpty
      ? trimmed
      : trimmed.substring(0, trimmed.length - emoji.length).trim();
}

String firstName(String name) {
  final trimmed = formatUserDisplayName(name);
  return trimmed.split(RegExp(r'\s+')).first;
}

String initialsFromName(String name) {
  final clean = name.trim();
  if (clean.isEmpty) return '?';
  final parts = clean.split(RegExp(r'\s+'));
  if (parts.length == 1) {
    return parts.first.characters.take(2).toString().toUpperCase();
  }
  return '${parts[0].characters.first}${parts[1].characters.first}'
      .toUpperCase();
}

String? extractLastEmoji(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  final last = trimmed.characters.last;
  final code = last.runes.first;
  if (code > 0x2600) return last;
  return null;
}

OverlayEntry? _activeSundaySnackEntry;
Timer? _activeSundaySnackTimer;

void showSundaySnack(BuildContext context, String message) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;

  _dismissActiveSundaySnack();

  final entry = OverlayEntry(
    builder: (context) => _SundaySnackNotice(
      message: _cleanSundaySnackMessage(message),
      isError: _isSundaySnackError(message),
    ),
  );

  _activeSundaySnackEntry = entry;
  overlay.insert(entry);
  _activeSundaySnackTimer = Timer(
    const Duration(seconds: 3),
    _dismissActiveSundaySnack,
  );
}

void _dismissActiveSundaySnack() {
  _activeSundaySnackTimer?.cancel();
  _activeSundaySnackTimer = null;

  final entry = _activeSundaySnackEntry;
  _activeSundaySnackEntry = null;
  entry?.remove();
}

String _cleanSundaySnackMessage(String message) {
  var clean = message.trim();
  final prefixes = [
    RegExp(r'^Error:\s*Exception:\s*', caseSensitive: false),
    RegExp(r'^Exception:\s*', caseSensitive: false),
    RegExp(r'^Error:\s*', caseSensitive: false),
  ];

  for (final prefix in prefixes) {
    clean = clean.replaceFirst(prefix, '');
  }

  clean = clean.trim();
  return clean.isEmpty ? message : clean;
}

bool _isSundaySnackError(String message) {
  final lower = message.trim().toLowerCase();
  return lower.startsWith('error:') ||
      lower.startsWith('exception:') ||
      lower.contains('no se pudo') ||
      lower.contains('fall');
}

IconData _sundaySnackIconForMessage(String message, bool isError) {
  if (isError) return Icons.error_outline_rounded;

  final lower = message.toLowerCase();
  if (lower.contains('cargando') ||
      lower.contains('guardando') ||
      lower.contains('actualizando')) {
    return Icons.hourglass_top_rounded;
  }

  if (lower.contains('enviado') ||
      lower.contains('actualizado') ||
      lower.contains('copiado') ||
      lower.contains('completado') ||
      lower.contains('publicado')) {
    return Icons.check_rounded;
  }

  return Icons.info_outline_rounded;
}

class _SundaySnackNotice extends StatelessWidget {
  final String message;
  final bool isError;

  const _SundaySnackNotice({required this.message, required this.isError});

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final maxWidth = math.min(media.size.width - 48, 380.0);
    final accent = isError ? const Color(0xFFD96558) : ssOrange;
    final icon = _sundaySnackIconForMessage(message, isError);

    return IgnorePointer(
      child: SafeArea(
        child: Center(
          child: TweenAnimationBuilder<double>(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            tween: Tween<double>(begin: 0, end: 1),
            builder: (context, value, child) {
              return Opacity(
                opacity: value,
                child: Transform.scale(
                  scale: 0.96 + (0.04 * value),
                  child: child,
                ),
              );
            },
            child: Material(
              color: Colors.transparent,
              child: Container(
                width: maxWidth,
                margin: const EdgeInsets.symmetric(horizontal: 24),
                padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
                decoration: BoxDecoration(
                  color: ssSurface,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: isError ? const Color(0xFFFFD7C2) : ssOrangeMid,
                    width: 1.4,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.14),
                      blurRadius: 30,
                      offset: const Offset(0, 14),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 54,
                      height: 54,
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(icon, color: accent, size: 30),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      message,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: ssText,
                        fontSize: 16,
                        height: 1.35,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
