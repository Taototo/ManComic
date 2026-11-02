part of 'components.dart';

const _fastAnimationDuration = Duration(milliseconds: 160);

/// 封面缩略图的解码宽度上限（物理像素）。
///
/// 列表格子宽约 160dp、长按预览的封面高 200dp，都远小于封面原图
/// （常见 1500×2000）。不设上限就会按原尺寸解码，一张封面占十几 MB，
/// 一屏十几张很快把图像缓存撑满、滚动掉帧。
///
/// 这里刻意用**同一个**常量给列表和长按预览：两者共用同一份解码缓存，
/// 预览弹出时可以直接命中列表里已经解码好的图，不会闪占位色。
const kCoverDecodeWidth = 720;