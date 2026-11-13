part of 'music_player_service.dart';

/// Songs AVPlayer, the iOS and macOS engine, cannot open. A format it never
/// opens plays from a FLAC copy FFmpeg makes; another song gets the copy
/// after AVPlayer fails on it. A song that still fails names its format and
/// gives way to the next one, for up to [_skipLimit] songs in a row and one
/// pass over the queue.
///
/// On Android only AAC gets a copy, and only after MediaPlayer fails on a
/// local file: raw AAC streams (`.aac`) are refused on some devices with
/// MEDIA_ERROR_UNKNOWN. Anything else, or a song FFmpeg cannot copy either,
/// reports MediaPlayer's own failure as before. A streamed song MediaPlayer
/// refuses is retried once as an MP3 transcode from the server ([streamRetry]).
class _MusicFormats {
  _MusicFormats(this.handler)
    : _copies = AvPlayerCopies(
        run: handler._dependencies.convertAudio,
        isDisposed: () => handler._disposed,
        directory: handler._dependencies.playbackCopies,
        isPinned: (path) =>
            path == handler._activeResolvedPath ||
            handler._autoMix.pinnedPaths.contains(path) ||
            handler._gapless.pinnedPaths.contains(path),
      );

  static const _skipLimit = 10;

  /// The network song whose transcode retry was last made, so one that fails
  /// again is not retried forever.
  String? _transcodedSource;

  final MusicPlayerHandler handler;
  final AvPlayerCopies _copies;

  bool owns(String? path) => path != null && _copies.ownsPath(path);

  /// AVPlayer plays the main and prepared decks: not a cast device, nor
  /// macOS exclusive output, which libmpv plays.
  bool get _avPlayer =>
      (handler._dependencies.isIOS || handler._dependencies.isMacOS) &&
      playbackEngine == PlaybackEngine.audioplayers &&
      !handler._cast.active &&
      !playbackExclusiveOutput.value;

  /// Android's MediaPlayer plays the main and prepared decks: not a cast
  /// device.
  bool get _androidPlayer =>
      handler._dependencies.isAndroid &&
      playbackEngine == PlaybackEngine.audioplayers &&
      !handler._cast.active;

  /// The Android format of [media], resolved to the local file [path]: the
  /// Library's format and source name it, else the file's own name, which
  /// is all a SAF song's temporary copy has.
  static AvPlayerFormat? _androidFormat(PlayableMedia media, String path) =>
      androidPlayerFormat(name: media.source, codec: media.format) ??
      androidPlayerFormat(name: path);

  static AvPlayerFormat? _format(PlayableMedia media) =>
      avPlayerFormat(name: media.source, codec: media.format) ??
      (MusicPlayerHandler._requiresDsd(media)
          ? avPlayerFormat(codec: 'dsd')
          : null);

  static bool _isUrl(String path) =>
      const {'http', 'https'}.contains(Uri.tryParse(path)?.scheme);

  /// What plays for [media]: a FLAC copy of a format AVPlayer never opens,
  /// or of a song it failed to open before, else its resolved source.
  Future<String?> resolve(PlayableMedia media) async {
    final path = await handler._resolveSource(media);
    if (path == null) return path;
    if (!_avPlayer) {
      // MediaPlayer already failed on this AAC song: play its copy at once
      // instead of failing again first.
      if (_androidPlayer && _copies.has(media.source)) {
        return await _copy(media, path, _androidFormat(media, path)) ?? path;
      }
      return path;
    }
    final format = _format(media);
    if (!(format?.never ?? false) && !_copies.has(media.source)) return path;
    return await _copy(media, path, format) ?? path;
  }

  /// A FLAC copy to try after AVPlayer could not open [path] for [media]:
  /// a local file, or a stream of a format some system versions open.
  /// Null when there is none to try. [error] is what the player threw.
  Future<String?> afterFailure(
    PlayableMedia media,
    String path, {
    Object? error,
  }) async {
    if (!_avPlayer) {
      return _androidPlayer ? _afterAndroidFailure(media, path, error) : null;
    }
    if (owns(path)) return null;
    final format = _format(media);
    // A format AVPlayer never opens already had its copy attempt.
    if (format != null && format.never) return null;
    if (_isUrl(path) ? format == null : !await fileExists(path)) return null;
    return _copy(media, path, format);
  }

  /// The URL to retry a streamed song from, transcoded to MP3, when Android's
  /// MediaPlayer cannot play the original (ALAC or AAC on a Navidrome server):
  /// [path] is the loopback URL the song streams from. Once per song, so a
  /// transcode that fails too gives its error. Null when there is no retry.
  Future<String?> streamRetry(
    PlayableMedia media,
    String path, {
    Object? error,
  }) async {
    if (!_androidPlayer || !_isLoopback(path) || !media.isNetwork) return null;
    if (error is UsbOutputUnavailable || _transcodedSource == media.source) {
      return null;
    }
    _transcodedSource = media.source;
    try {
      return await handler._dependencies.resolveNetworkTranscode(media.source);
    } catch (_) {
      return null;
    }
  }

  static bool _isLoopback(String path) => path.startsWith('http://127.0.0.1:');

  /// A FLAC copy to try after Android's MediaPlayer could not open the AAC
  /// file [path] of [media]; null when there is none to try. Local files
  /// only: FFmpeg would read a stream to its end before anything played, and
  /// a SAF song's `/proc` descriptor cannot be reopened. That song falls back
  /// to a temporary local copy, which comes here next. A refused USB output
  /// is not a format failure, and a copy of it would not change that.
  Future<String?> _afterAndroidFailure(
    PlayableMedia media,
    String path,
    Object? error,
  ) async {
    if (error is UsbOutputUnavailable ||
        owns(path) ||
        _isUrl(path) ||
        path.startsWith('content://') ||
        path.startsWith('/proc/self/fd/')) {
      return null;
    }
    final format = _androidFormat(media, path);
    if (format == null || !await fileExists(path)) return null;
    return _copy(media, path, format);
  }

  Future<String?> _copy(
    PlayableMedia media,
    String path,
    AvPlayerFormat? format,
  ) async {
    final copy = await _copies.resolve(
      media.source,
      path,
      format: format,
      sampleRate: media.sampleRate,
      dsd: MusicPlayerHandler._requiresDsd(media),
    );
    if (copy != null) {
      _log.i('Playing ${format?.label ?? 'a song'} from a FLAC copy');
    }
    return copy;
  }

  Future<void> invalidate(String source) => _copies.invalidate(source);

  /// Reports that AVPlayer could not play the current [media], resolved to
  /// [path], by its format, and plays the next song in its place unless it
  /// is the last, repeats alone, starts paused or ends a run of failures.
  /// False leaves the failure to the caller to report.
  Future<bool> skipUnplayable(
    PlayableMedia media,
    String? path,
    int generation, {
    required bool startPaused,
  }) async {
    if (!_avPlayer || path == null) return false;
    final format = _format(media);
    // A missing file, or a stream of a format AVPlayer opens, failed for
    // another reason.
    if (_isUrl(path) ? format == null : !await fileExists(path)) return false;
    if (!handler._isCurrentPlayRequest(generation, media)) return true;
    final extension = fileExtension(media.source).toUpperCase();
    final codec = media.format?.trim().toUpperCase() ?? '';
    final label =
        format?.label ??
        (codec.isNotEmpty ? codec : (extension.isNotEmpty ? extension : null));
    if (label == null) return false;
    final skip = handler._failures.canSkip(
      generation,
      startPaused: startPaused,
      limit: _skipLimit,
    );
    handler._runtime.notifyUnplayableSong(label, skipped: skip);
    _log.w('AVPlayer cannot play ${media.title} ($label)');
    if (!skip) return false;
    handler._failures.playNext();
    return true;
  }

  Future<void> dispose() => _copies.dispose();
}
