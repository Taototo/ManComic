import 'package:mime/mime.dart';

class FileType {
  final String ext;
  final String mime;

  const FileType(this.ext, this.mime);

  static FileType fromExtension(String ext) {
    if(ext.startsWith('.')) {
      ext = ext.substring(1);
    }
    var mime = lookupMimeType('no-file.$ext') ?? 'application/octet-stream';
    // Android doesn't support some mime types
    mime = switch(mime) {
      'text/javascript' => 'application/octet-stream',
      'application/x-cbr' => 'application/octet-stream',
      _ => mime,
    };
    return FileType(".$ext", mime);
  }
}

final _resolver = MimeTypeResolver()
  // zip
  ..addMagicNumber([0x50, 0x4B], 'application/zip')
  // 7z
  ..addMagicNumber([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C], 'application/x-7z-compressed')
  // rar
  ..addMagicNumber([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07], 'application/vnd.rar')
  // avif
  ..addMagicNumber([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x61, 0x76, 0x69, 0x66], 'image/avif')
;

FileType detectFileType(List<int> data) {
  var mime = _resolver.lookup('no-file', headerBytes: data);
  var ext = mime == null ? '' : extensionFromMime(mime);
  if(ext == 'jpe') {
    ext = 'jpg';
  }
  return FileType(".$ext", mime ?? 'application/octet-stream');
}

bool _endsWith(List<int> data, List<int> tail, {int slack = 0}) {
  // 允许结尾带几个填充字节：有的源站会在图片后面补 0 或者换行。
  for (var pad = 0; pad <= slack; pad++) {
    if (data.length < tail.length + pad) {
      continue;
    }
    var end = data.length - pad;
    var matched = true;
    for (var i = 0; i < tail.length; i++) {
      if (data[end - tail.length + i] != tail[i]) {
        matched = false;
        break;
      }
    }
    if (matched) {
      return true;
    }
  }
  return false;
}

bool _hasAsciiAt(List<int> data, int offset, String text) {
  if (data.length < offset + text.length) {
    return false;
  }
  for (var i = 0; i < text.length; i++) {
    if (data[offset + i] != text.codeUnitAt(i)) {
      return false;
    }
  }
  return true;
}

/// 这段字节是不是一张**完整**的图片。
///
/// 为什么需要：断线时 dio 的响应流可能直接结束而不抛异常，缓冲区里只收到
/// 半张图，上层拿到「有 imageBytes」就当下载成功写进磁盘（甚至连同缓存），
/// 于是封面和页面永远打不开；更糟的是任务记录里已经记成「下过了」，恢复
/// 下载时会被整个跳过，重下也不会自动修。
///
/// 这里按容器格式的结束标记判断，只做常数级比较，不解码、不花时间。
/// 认不出的格式（avif 等）只要非空就放行——宁可放过，不要误杀。
bool isCompleteImageBytes(List<int> data) {
  if (data.length < 12) {
    return false;
  }
  // JPEG：SOI ... EOI
  if (data[0] == 0xFF && data[1] == 0xD8) {
    return _endsWith(data, const [0xFF, 0xD9], slack: 8);
  }
  // PNG：8 字节签名，结尾是 IEND 块（长度 0 + 类型 + 固定 CRC）
  if (data[0] == 0x89 &&
      data[1] == 0x50 &&
      data[2] == 0x4E &&
      data[3] == 0x47) {
    return _endsWith(
      data,
      const [0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82],
      slack: 8,
    );
  }
  // GIF：结束符 0x3B
  if (data[0] == 0x47 && data[1] == 0x49 && data[2] == 0x46) {
    return data.last == 0x3B;
  }
  // WebP：RIFF 容器，长度字段写在头部，必须和实际长度对得上
  if (_hasAsciiAt(data, 0, 'RIFF') && _hasAsciiAt(data, 8, 'WEBP')) {
    final size = data[4] | data[5] << 8 | data[6] << 16 | data[7] << 24;
    return size + 8 == data.length;
  }
  return true;
}
