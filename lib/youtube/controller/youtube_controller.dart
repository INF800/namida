import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:youtipie/class/streams/audio_stream.dart';
import 'package:youtipie/class/streams/video_stream.dart';
import 'package:youtipie/class/streams/video_streams_result.dart';
import 'package:youtipie/youtipie.dart';

import 'package:namida/base/ports_provider.dart';
import 'package:namida/class/http_response_wrapper.dart';
import 'package:namida/class/video.dart';
import 'package:namida/controller/ffmpeg_controller.dart';
import 'package:namida/controller/notification_controller.dart';
import 'package:namida/controller/settings_controller.dart';
import 'package:namida/controller/thumbnail_manager.dart';
import 'package:namida/core/constants.dart';
import 'package:namida/core/extensions.dart';
import 'package:namida/core/namida_converter_ext.dart';
import 'package:namida/core/utils.dart';
import 'package:namida/youtube/class/download_progress.dart';
import 'package:namida/youtube/class/download_task_base.dart';
import 'package:namida/youtube/class/youtube_item_download_config.dart';
import 'package:namida/youtube/controller/parallel_downloads_controller.dart';
import 'package:namida/youtube/controller/youtube_info_controller.dart';
import 'package:namida/youtube/controller/youtube_ongoing_finished_downloads.dart';
import 'package:namida/youtube/widgets/yt_thumbnail.dart';
import 'package:namida/youtube/yt_utils.dart';

class _YTNotificationDataHolder {
  late final _speedMapVideo = <DownloadTaskFilename, int>{};
  late final _speedMapAudio = <DownloadTaskFilename, int>{};

  late final _titlesLookupTemp = <DownloadTaskVideoId, String?>{};
  late final _imagesLookupTemp = <DownloadTaskVideoId, File?>{};

  String? titleCallback(DownloadTaskVideoId videoId) {
    return _titlesLookupTemp[videoId] ??= YoutubeInfoController.utils.getVideoName(videoId.videoId);
  }

  File? imageCallback(DownloadTaskVideoId videoId) {
    return _imagesLookupTemp[videoId] ??= ThumbnailManager.inst.getYoutubeThumbnailFromCacheSync(id: videoId.videoId, type: ThumbnailType.video);
  }

  void clearAll() {
    _speedMapVideo.clear();
    _speedMapAudio.clear();
    _titlesLookupTemp.clear();
    _imagesLookupTemp.clear();
  }
}

class YoutubeController {
  static YoutubeController get inst => _instance;
  static final YoutubeController _instance = YoutubeController._internal();
  YoutubeController._internal();

  /// {id: <filename, DownloadProgress>{}}
  final downloadsVideoProgressMap = <DownloadTaskVideoId, RxMap<DownloadTaskFilename, DownloadProgress>>{}.obs;

  /// {id: <filename, DownloadProgress>{}}
  final downloadsAudioProgressMap = <DownloadTaskVideoId, RxMap<DownloadTaskFilename, DownloadProgress>>{}.obs;

  /// {id: <filename, int>{}}
  final currentSpeedsInByte = <DownloadTaskVideoId, RxMap<DownloadTaskFilename, int>>{}.obs;

  /// {id: <filename, bool>{}}
  final isDownloading = <DownloadTaskVideoId, RxMap<DownloadTaskFilename, bool>>{}.obs;

  /// {id: <filename, bool>{}}
  final isFetchingData = <DownloadTaskVideoId, RxMap<DownloadTaskFilename, bool>>{}.obs;

  /// {groupName: <File>{}}
  final _downloadClientsMap = <DownloadTaskGroupName, Map<DownloadTaskFilename, File>>{};

  /// {groupName: {filename: YoutubeItemDownloadConfig}}
  final youtubeDownloadTasksMap = <DownloadTaskGroupName, Map<DownloadTaskFilename, YoutubeItemDownloadConfig>>{}.obs;

  /// {groupName: {filename: bool}}
  /// - `true` -> is in queue, will be downloaded when reached.
  /// - `false` -> is paused. will be skipped when reached.
  /// - `null` -> not specified.
  final youtubeDownloadTasksInQueueMap = <DownloadTaskGroupName, Map<DownloadTaskFilename, bool?>>{}.obs;

  /// {groupName: dateMS}
  ///
  /// used to sort group names by latest edited.
  final latestEditedGroupDownloadTask = <DownloadTaskGroupName, int>{};

  /// Used to keep track of existing downloaded files, more performant than real-time checking.
  ///
  /// {groupName: {filename: File}}
  final downloadedFilesMap = <DownloadTaskGroupName, Map<DownloadTaskFilename, File?>>{}.obs;

  late final _notificationData = _YTNotificationDataHolder();

  /// [renameCacheFiles] requires you to stop the download first, otherwise it might result in corrupted files.
  Future<void> renameConfigFilename({
    required YoutubeItemDownloadConfig config,
    required DownloadTaskVideoId videoID,
    required DownloadTaskFilename newFilename,
    required DownloadTaskGroupName groupName,
    required bool renameCacheFiles,
  }) async {
    final oldFilename = config.filename;

    // ignore: invalid_use_of_protected_member
    config.rename(newFilename);

    downloadsVideoProgressMap[videoID]?.reAssign(oldFilename, newFilename);
    downloadsAudioProgressMap[videoID]?.reAssign(oldFilename, newFilename);
    currentSpeedsInByte[videoID]?.reAssign(oldFilename, newFilename);
    isDownloading[videoID]?.reAssign(oldFilename, newFilename);
    isFetchingData[videoID]?.reAssign(oldFilename, newFilename);

    downloadsVideoProgressMap.refresh();
    downloadsAudioProgressMap.refresh();
    currentSpeedsInByte.refresh();
    isDownloading.refresh();
    isFetchingData.refresh();

    // =============

    _downloadClientsMap[groupName]?.reAssign(oldFilename, newFilename);
    youtubeDownloadTasksMap[groupName]?.reAssign(oldFilename, newFilename);
    youtubeDownloadTasksInQueueMap[groupName]?.reAssignNullable(oldFilename, newFilename);
    downloadedFilesMap[groupName]?.reAssignNullable(oldFilename, newFilename);

    youtubeDownloadTasksMap.refresh();
    youtubeDownloadTasksInQueueMap.refresh();
    downloadedFilesMap.refresh();

    final directory = Directory("${AppDirs.YOUTUBE_DOWNLOADS}${groupName.groupName}");
    final existingFile = File("${directory.path}/${config.filename.filename}");
    if (existingFile.existsSync()) {
      try {
        existingFile.renameSync("${directory.path}/${newFilename.filename}");
      } catch (_) {}
    }
    if (renameCacheFiles) {
      final aFile = File(_getTempAudioPath(groupName: groupName, fullFilename: oldFilename));
      final vFile = File(_getTempVideoPath(groupName: groupName, fullFilename: oldFilename));

      if (aFile.existsSync()) {
        final newPath = _getTempAudioPath(groupName: groupName, fullFilename: newFilename);
        aFile.renameSync(newPath);
      }
      if (vFile.existsSync()) {
        final newPath = _getTempVideoPath(groupName: groupName, fullFilename: newFilename);
        vFile.renameSync(newPath);
      }
    }

    NotificationService.inst.removeDownloadingYoutubeNotification(notificationID: oldFilename);

    YTOnGoingFinishedDownloads.inst.refreshList();

    await _writeTaskGroupToStorage(groupName: groupName);
  }

  VideoStream? getPreferredStreamQuality(List<VideoStream> streams, {List<String> qualities = const [], bool preferIncludeWebm = false}) {
    if (streams.isEmpty) return null;
    final preferredQualities = (qualities.isNotEmpty ? qualities : settings.youtubeVideoQualities.value).map((element) => element.settingLabeltoVideoLabel());
    VideoStream? plsLoop(bool webm) {
      for (int i = 0; i < streams.length; i++) {
        final q = streams[i];
        final webmCondition = webm ? true : !q.isWebm;
        if (webmCondition && preferredQualities.contains(q.qualityLabel.splitFirst('p'))) {
          return q;
        }
      }
      return null;
    }

    if (preferIncludeWebm) {
      return plsLoop(true) ?? streams.last;
    } else {
      return plsLoop(false) ?? plsLoop(true) ?? streams.last;
    }
  }

  void _loopMapAndPostNotification({
    required Map<DownloadTaskVideoId, RxMap<DownloadTaskFilename, DownloadProgress>> bigMap,
    required int Function(DownloadTaskFilename key, int progress) speedInBytes,
    required DateTime startTime,
    required bool isAudio,
    required String? Function(DownloadTaskVideoId videoId) titleCallback,
    required File? Function(DownloadTaskVideoId videoId) imageCallback,
  }) {
    final downloadingText = isAudio ? "Audio" : "Video";
    for (final bigEntry in bigMap.entries.toList()) {
      final map = bigEntry.value.value;
      final videoId = bigEntry.key;
      for (final entry in map.entries.toList()) {
        final p = entry.value.progress;
        final tp = entry.value.totalProgress;
        final percentage = p / tp;
        if (percentage.isNaN || percentage.isInfinite || percentage >= 1) {
          map.remove(entry.key);
        } else {
          final filename = entry.key;
          final title = titleCallback(videoId) ?? videoId;
          final speedB = speedInBytes(filename, entry.value.progress);
          if (currentSpeedsInByte.value[videoId] == null) {
            currentSpeedsInByte.value[videoId] = <DownloadTaskFilename, int>{}.obs;
            currentSpeedsInByte.refresh();
          }

          currentSpeedsInByte.value[videoId]![filename] = speedB;
          NotificationService.inst.downloadYoutubeNotification(
            notificationID: entry.key,
            title: "Downloading $downloadingText: $title",
            progress: p,
            total: tp,
            subtitle: (progressText) => "$progressText (${speedB.fileSizeFormatted}/s)",
            imagePath: imageCallback(videoId)?.path,
            displayTime: startTime,
          );
        }
      }
    }
  }

  void _doneDownloadingNotification({
    required DownloadTaskVideoId videoId,
    required String videoTitle,
    required DownloadTaskFilename nameIdentifier,
    required File? downloadedFile,
    required DownloadTaskFilename filename,
    required bool canceledByUser,
  }) {
    if (downloadedFile == null) {
      if (!canceledByUser) {
        NotificationService.inst.doneDownloadingYoutubeNotification(
          notificationID: nameIdentifier,
          videoTitle: videoTitle,
          subtitle: 'Download Failed',
          imagePath: _notificationData.imageCallback(videoId)?.path,
          failed: true,
        );
      }
    } else {
      final size = downloadedFile.fileSizeFormatted();
      NotificationService.inst.doneDownloadingYoutubeNotification(
        notificationID: nameIdentifier,
        videoTitle: downloadedFile.path.getFilenameWOExt,
        subtitle: size == null ? '' : 'Downloaded: $size',
        imagePath: _notificationData.imageCallback(videoId)?.path,
        failed: false,
      );
    }
    _tryCancelDownloadNotificationTimer();

    // this removes progress when pausing.
    // downloadsVideoProgressMap[videoId]?.remove(filename);
    // downloadsAudioProgressMap[videoId]?.remove(filename);
  }

  Timer? _downloadNotificationTimer;
  void _tryCancelDownloadNotificationTimer() {
    if (downloadsVideoProgressMap.isEmpty && downloadsAudioProgressMap.isEmpty) {
      _downloadNotificationTimer?.cancel();
      _downloadNotificationTimer = null;
      _notificationData.clearAll();
    }
  }

  void _startNotificationTimer() {
    if (_downloadNotificationTimer == null) {
      final startTime = DateTime.now();

      _downloadNotificationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        _loopMapAndPostNotification(
          startTime: startTime,
          isAudio: false,
          bigMap: downloadsVideoProgressMap.value,
          speedInBytes: (key, newProgress) {
            final previousProgress = _notificationData._speedMapVideo[key] ?? 0;
            final speed = newProgress - previousProgress;
            _notificationData._speedMapVideo[key] = newProgress;
            return speed;
          },
          titleCallback: _notificationData.titleCallback,
          imageCallback: _notificationData.imageCallback,
        );
        _loopMapAndPostNotification(
          startTime: startTime,
          isAudio: true,
          bigMap: downloadsAudioProgressMap.value,
          speedInBytes: (key, newProgress) {
            final previousProgress = _notificationData._speedMapAudio[key] ?? 0;
            final speed = newProgress - previousProgress;
            _notificationData._speedMapAudio[key] = newProgress;
            return speed;
          },
          titleCallback: _notificationData.titleCallback,
          imageCallback: _notificationData.imageCallback,
        );
      });
    }
  }

  static const String cleanupFilenameRegex = r'[*#\$|/\\!^:"]';
  String cleanupFilename(String filename) => filename.replaceAll(RegExp(cleanupFilenameRegex, caseSensitive: false), '_');

  Future<void> loadDownloadTasksInfoFile() async {
    await for (final f in Directory(AppDirs.YT_DOWNLOAD_TASKS).list()) {
      if (f is File) {
        final groupName = DownloadTaskGroupName(groupName: f.path.getFilename.splitFirst('.'));
        final res = await f.readAsJson() as Map<String, dynamic>?;
        if (res != null) {
          final fileModified = f.statSync().modified;
          youtubeDownloadTasksMap[groupName] ??= {};
          downloadedFilesMap[groupName] ??= {};
          if (fileModified != DateTime(1970)) {
            latestEditedGroupDownloadTask[groupName] ??= fileModified.millisecondsSinceEpoch;
          }
          for (final v in res.entries) {
            final ytitem = YoutubeItemDownloadConfig.fromJson(v.value as Map<String, dynamic>);
            final saveDirPath = "${AppDirs.YOUTUBE_DOWNLOADS}${groupName.groupName}";
            final file = File("$saveDirPath/${ytitem.filename.filename}");
            final fileExists = file.existsSync();
            final itemFileName = DownloadTaskFilename(initialFilename: v.key);
            youtubeDownloadTasksMap[groupName]![itemFileName] = ytitem;
            downloadedFilesMap[groupName]![itemFileName] = fileExists ? file : null;
            if (!fileExists) {
              final aFile = File("$saveDirPath/.tempa_${ytitem.filename.filename}");
              final vFile = File("$saveDirPath/.tempv_${ytitem.filename.filename}");
              if (aFile.existsSync()) {
                if (downloadsAudioProgressMap.value[ytitem.id] == null) {
                  downloadsAudioProgressMap.value[ytitem.id] = <DownloadTaskFilename, DownloadProgress>{}.obs;
                  downloadsAudioProgressMap.refresh();
                }
                downloadsAudioProgressMap.value[ytitem.id]![ytitem.filename] = DownloadProgress(
                  progress: aFile.fileSizeSync() ?? 0,
                  totalProgress: 0,
                );
              }
              if (vFile.existsSync()) {
                if (downloadsVideoProgressMap.value[ytitem.id] == null) {
                  downloadsVideoProgressMap.value[ytitem.id] = <DownloadTaskFilename, DownloadProgress>{}.obs;
                  downloadsVideoProgressMap.refresh();
                }
                downloadsVideoProgressMap.value[ytitem.id]![ytitem.filename] = DownloadProgress(
                  progress: vFile.fileSizeSync() ?? 0,
                  totalProgress: 0,
                );
              }
            }
          }
        }
      }
    }
    youtubeDownloadTasksMap.refresh();
    downloadedFilesMap.refresh();
  }

  File? doesIDHasFileDownloaded(String id) {
    for (final e in youtubeDownloadTasksMap.entries) {
      for (final config in e.value.values) {
        final groupName = e.key;
        if (config.id.videoId == id) {
          final file = downloadedFilesMap[groupName]?[config.filename];
          if (file != null) {
            return file;
          }
        }
      }
    }
    return null;
  }

  void _matchIDsForItemConfig({
    required List<DownloadTaskVideoId> videosIds,
    required void Function(DownloadTaskGroupName groupName, YoutubeItemDownloadConfig config) onMatch,
  }) {
    for (final e in youtubeDownloadTasksMap.entries) {
      for (final config in e.value.values) {
        final groupName = e.key;
        videosIds.loop((e) {
          if (e == config.id) {
            onMatch(groupName, config);
          }
        });
      }
    }
  }

  void resumeDownloadTaskForIDs({
    required DownloadTaskGroupName groupName,
    List<DownloadTaskVideoId> videosIds = const [],
  }) {
    _matchIDsForItemConfig(
      videosIds: videosIds,
      onMatch: (groupName, config) {
        downloadYoutubeVideos(
          useCachedVersionsIfAvailable: true,
          autoExtractTitleAndArtist: settings.ytAutoExtractVideoTagsFromInfo.value,
          keepCachedVersionsIfDownloaded: settings.downloadFilesKeepCachedVersions.value,
          downloadFilesWriteUploadDate: settings.downloadFilesWriteUploadDate.value,
          itemsConfig: [config],
          groupName: groupName,
        );
      },
    );
  }

  Future<void> resumeDownloadTasks({
    required DownloadTaskGroupName groupName,
    List<YoutubeItemDownloadConfig> itemsConfig = const [],
    bool skipExistingFiles = true,
  }) async {
    final finalItems = itemsConfig.isNotEmpty ? itemsConfig : youtubeDownloadTasksMap[groupName]?.values.toList() ?? [];
    if (skipExistingFiles) {
      finalItems.removeWhere((element) => YoutubeController.inst.downloadedFilesMap[groupName]?[element.filename] != null);
    }
    if (finalItems.isNotEmpty) {
      await downloadYoutubeVideos(
        useCachedVersionsIfAvailable: true,
        autoExtractTitleAndArtist: settings.ytAutoExtractVideoTagsFromInfo.value,
        keepCachedVersionsIfDownloaded: settings.downloadFilesKeepCachedVersions.value,
        downloadFilesWriteUploadDate: settings.downloadFilesWriteUploadDate.value,
        itemsConfig: finalItems,
        groupName: groupName,
      );
    }
  }

  void pauseDownloadTask({
    required List<YoutubeItemDownloadConfig> itemsConfig,
    required DownloadTaskGroupName groupName,
    List<DownloadTaskVideoId> videosIds = const [],
    bool allInGroupName = false,
  }) {
    youtubeDownloadTasksInQueueMap[groupName] ??= {};
    void onMatch(DownloadTaskGroupName groupName, YoutubeItemDownloadConfig config) {
      youtubeDownloadTasksInQueueMap[groupName]![config.filename] = false;
      _downloadManager.stopDownload(file: _downloadClientsMap[groupName]?[config.filename]);
      _downloadClientsMap[groupName]?.remove(config.filename);
      _breakRetrievingInfoRequest(config);
    }

    if (allInGroupName) {
      final groupClients = _downloadClientsMap[groupName];
      if (groupClients != null) {
        _downloadManager.stopDownloads(files: groupClients.values.toList());
        _downloadClientsMap.remove(groupName);
      }
      final groupConfigs = youtubeDownloadTasksMap[groupName];
      if (groupConfigs != null) {
        for (final c in groupConfigs.values) {
          onMatch(groupName, c);
        }
      }
    } else if (videosIds.isNotEmpty) {
      _matchIDsForItemConfig(
        videosIds: videosIds,
        onMatch: onMatch,
      );
    } else {
      itemsConfig.loop((c) => onMatch(groupName, c));
    }
    youtubeDownloadTasksInQueueMap.refresh();
  }

  void _breakRetrievingInfoRequest(YoutubeItemDownloadConfig c) {
    final err = Exception('Download was canceled by the user');
    _completersVAI[c]?.completeErrorIfWasnt(err);
  }

  Future<void> cancelDownloadTask({
    required List<YoutubeItemDownloadConfig> itemsConfig,
    required DownloadTaskGroupName groupName,
    bool allInGroupName = false,
    bool keepInList = false,
  }) async {
    await _updateDownloadTask(
      itemsConfig: itemsConfig,
      groupName: groupName,
      remove: true,
      keepInListIfRemoved: keepInList,
      allInGroupName: allInGroupName,
    );
  }

  Future<void> _updateDownloadTask({
    required List<YoutubeItemDownloadConfig> itemsConfig,
    required DownloadTaskGroupName groupName,
    bool remove = false,
    bool keepInListIfRemoved = false,
    bool allInGroupName = false,
  }) async {
    youtubeDownloadTasksMap[groupName] ??= {};
    youtubeDownloadTasksInQueueMap[groupName] ??= {};
    if (remove) {
      final directory = Directory("${AppDirs.YOUTUBE_DOWNLOADS}${groupName.groupName}");
      final itemsToCancel = allInGroupName ? youtubeDownloadTasksMap[groupName]!.values.toList() : itemsConfig;
      for (final c in itemsToCancel) {
        _downloadManager.stopDownload(file: _downloadClientsMap[groupName]?[c.filename]);
        _downloadClientsMap[groupName]?.remove(c.filename);
        _breakRetrievingInfoRequest(c);
        if (!keepInListIfRemoved) {
          youtubeDownloadTasksMap[groupName]?.remove(c.filename);
          youtubeDownloadTasksInQueueMap[groupName]?.remove(c.filename);
          YTOnGoingFinishedDownloads.inst.youtubeDownloadTasksTempList.remove((groupName, c));
        }
        try {
          await File("$directory/${c.filename.filename}").delete();
        } catch (_) {}
        downloadedFilesMap[groupName]?[c.filename] = null;
      }

      // -- remove groups if emptied.
      if (youtubeDownloadTasksMap[groupName]?.isEmpty == true) {
        youtubeDownloadTasksMap.remove(groupName);
      }
    } else {
      itemsConfig.loop((c) {
        youtubeDownloadTasksMap[groupName]![c.filename] = c;
        youtubeDownloadTasksInQueueMap[groupName]![c.filename] = true;
      });
    }

    youtubeDownloadTasksMap.refresh();
    downloadedFilesMap.refresh();

    latestEditedGroupDownloadTask[groupName] = DateTime.now().millisecondsSinceEpoch;

    await _writeTaskGroupToStorage(groupName: groupName);
  }

  Future<void> _writeTaskGroupToStorage({required DownloadTaskGroupName groupName}) async {
    final mapToWrite = youtubeDownloadTasksMap[groupName];
    final file = File("${AppDirs.YT_DOWNLOAD_TASKS}${groupName.groupName}.json");
    if (mapToWrite != null && mapToWrite.isNotEmpty) {
      final jsonMap = <String, Map<String, dynamic>>{};
      for (final k in mapToWrite.keys) {
        final val = mapToWrite[k];
        if (val != null) jsonMap[k.filename] = val.toJson();
      }
      file.writeAsJsonSync(jsonMap); // sync cuz
    } else {
      await file.tryDeleting();
    }
  }

  final _completersVAI = <YoutubeItemDownloadConfig, Completer<VideoStreamsResult>>{};

  Future<void> downloadYoutubeVideos({
    required List<YoutubeItemDownloadConfig> itemsConfig,
    DownloadTaskGroupName groupName = const DownloadTaskGroupName.defaulty(),
    int parallelDownloads = 1,
    required bool useCachedVersionsIfAvailable,
    required bool downloadFilesWriteUploadDate,
    required bool keepCachedVersionsIfDownloaded,
    required bool autoExtractTitleAndArtist,
    bool deleteOldFile = true,
    bool addAudioToLocalLibrary = true,
    bool audioOnly = false,
    List<String> preferredQualities = const [],
    Future<void> Function(File? downloadedFile)? onOldFileDeleted,
    Future<void> Function(File? deletedFile)? onFileDownloaded,
    Directory? saveDirectory,
  }) async {
    _updateDownloadTask(groupName: groupName, itemsConfig: itemsConfig);
    YoutubeParallelDownloadsHandler.inst.setMaxParalellDownloads(parallelDownloads);

    Future<void> downloady(YoutubeItemDownloadConfig config) async {
      final videoID = config.id;

      final completer = _completersVAI[config] = Completer<VideoStreamsResult>();
      final streamResultSync = YoutubeInfoController.video.fetchVideoStreamsSync(videoID.videoId);
      if (streamResultSync != null && streamResultSync.hasExpired() == false) {
        completer.completeIfWasnt(streamResultSync);
      } else {
        YoutubeInfoController.video.fetchVideoStreams(videoID.videoId).then((value) => completer.completeIfWasnt(value));
      }
      if (isFetchingData.value[videoID] == null) {
        isFetchingData.value[videoID] = <DownloadTaskFilename, bool>{}.obs;
        isFetchingData.refresh();
      }
      isFetchingData.value[videoID]![config.filename] = true;

      try {
        final streams = await completer.future;

        // -- video
        if (config.fetchMissingVideo == true) {
          final videos = streams.videoStreams;
          if (config.prefferedVideoQualityID != null) {
            config.videoStream = videos.firstWhereEff((e) => e.itag.toString() == config.prefferedVideoQualityID);
          }
          if (config.videoStream == null || config.videoStream?.buildUrl()?.isNotEmpty != true) {
            final webm = config.filename.filename.endsWith('.webm') || config.filename.filename.endsWith('.WEBM');
            config.videoStream = getPreferredStreamQuality(videos, qualities: preferredQualities, preferIncludeWebm: webm);
          }
        }

        if (config.fetchMissingAudio == true) {
          // -- audio
          final audios = streams.audioStreams;
          if (config.prefferedAudioQualityID != null) {
            config.audioStream = audios.firstWhereEff((e) => e.itag.toString() == config.prefferedAudioQualityID);
          }
          if (config.audioStream == null || config.audioStream?.buildUrl()?.isNotEmpty != true) {
            config.audioStream = audios.firstNonWebm() ?? audios.firstOrNull;
          }
        }

        // -- meta info
        if (config.ffmpegTags.isEmpty) {
          final info = streams.info;
          final meta = YTUtils.getMetadataInitialMap(videoID.videoId, info, autoExtract: autoExtractTitleAndArtist);

          config.ffmpegTags.addAll(meta);
          config.fileDate = info?.publishDate.date ?? info?.uploadDate.date;
        }
      } catch (e) {
        // -- force break
        isFetchingData.value[videoID]?[config.filename] = false;
        return;
      }

      isFetchingData.value[videoID]?[config.filename] = false;
      _updateDownloadTask(groupName: groupName, itemsConfig: [config]); // to refresh with new data

      final downloadedFile = await _downloadYoutubeVideoRaw(
        groupName: groupName,
        id: videoID,
        config: config,
        useCachedVersionsIfAvailable: useCachedVersionsIfAvailable,
        saveDirectory: saveDirectory,
        fileExtension: config.videoStream?.codecInfo.container ?? config.audioStream?.codecInfo.container ?? '',
        videoStream: config.videoStream,
        audioStream: config.audioStream,
        merge: true,
        deleteOldFile: deleteOldFile,
        onOldFileDeleted: onOldFileDeleted,
        keepCachedVersionsIfDownloaded: keepCachedVersionsIfDownloaded,
        videoDownloadingStream: (downloadedBytes) {},
        audioDownloadingStream: (downloadedBytes) {},
        onInitialVideoFileSize: (initialFileSize) {},
        onInitialAudioFileSize: (initialFileSize) {},
        ffmpegTags: config.ffmpegTags,
        onAudioFileReady: (audioFile) async {
          final thumbnailFile = await ThumbnailManager.inst.getYoutubeThumbnailAndCache(
            id: videoID.videoId,
            isImportantInCache: true,
            type: ThumbnailType.video,
          );
          await YTUtils.writeAudioMetadata(
            videoId: videoID.videoId,
            audioFile: audioFile,
            thumbnailFile: thumbnailFile,
            tagsMap: config.ffmpegTags,
          );
        },
        onVideoFileReady: (videoFile) async {
          await NamidaFFMPEG.inst.editMetadata(
            path: videoFile.path,
            tagsMap: config.ffmpegTags,
          );
        },
      );

      if (downloadFilesWriteUploadDate) {
        final d = config.fileDate;
        if (d != null && d != DateTime(0)) {
          try {
            await downloadedFile?.setLastAccessed(d);
            await downloadedFile?.setLastModified(d);
          } catch (_) {}
        }
      }

      // -- adding to library, only if audio downloaded
      if (addAudioToLocalLibrary && config.audioStream != null && config.videoStream == null) {
        downloadedFile?.path.removeTrackThenExtract();
      }

      downloadedFilesMap[groupName]?[config.filename] = downloadedFile;
      downloadedFilesMap.refresh();
      YTOnGoingFinishedDownloads.inst.refreshList();
      await onFileDownloaded?.call(downloadedFile);
    }

    bool checkIfCanSkip(YoutubeItemDownloadConfig config) {
      final isCanceled = youtubeDownloadTasksMap[groupName]?[config.filename] == null;
      final isPaused = youtubeDownloadTasksInQueueMap[groupName]?[config.filename] == false;
      if (isCanceled || isPaused) {
        printy('Download Skipped for "${config.filename.filename}" bcz: canceled? $isCanceled, paused? $isPaused');
        return true;
      }
      return false;
    }

    for (final config in itemsConfig) {
      // if paused, or removed (canceled), we skip it
      if (checkIfCanSkip(config)) continue;

      await YoutubeParallelDownloadsHandler.inst.waitForParallelCompleter;

      // we check again bcz we been waiting...
      if (checkIfCanSkip(config)) continue;

      YoutubeParallelDownloadsHandler.inst.inc();
      await downloady(config).then((value) {
        YoutubeParallelDownloadsHandler.inst.dec();
      });
    }
  }

  String _getTempAudioPath({
    required DownloadTaskGroupName groupName,
    required DownloadTaskFilename fullFilename,
    Directory? saveDir,
  }) {
    return _getTempDownloadPath(
      groupName: groupName.groupName,
      fullFilename: fullFilename.filename,
      prefix: '.tempa_',
      saveDir: saveDir,
    );
  }

  String _getTempVideoPath({
    required DownloadTaskGroupName groupName,
    required DownloadTaskFilename fullFilename,
    Directory? saveDir,
  }) {
    return _getTempDownloadPath(
      groupName: groupName.groupName,
      fullFilename: fullFilename.filename,
      prefix: '.tempv_',
      saveDir: saveDir,
    );
  }

  /// [directoryPath] must NOT end with `/`
  String _getTempDownloadPath({
    required String groupName,
    required String fullFilename,
    required String prefix,
    Directory? saveDir,
  }) {
    final saveDirPath = saveDir?.path ?? "${AppDirs.YOUTUBE_DOWNLOADS}$groupName";
    return "$saveDirPath/$prefix$fullFilename";
  }

  Future<File?> _downloadYoutubeVideoRaw({
    required DownloadTaskVideoId id,
    required DownloadTaskGroupName groupName,
    required YoutubeItemDownloadConfig config,
    required bool useCachedVersionsIfAvailable,
    required Directory? saveDirectory,
    required String fileExtension,
    required VideoStream? videoStream,
    required AudioStream? audioStream,
    required Map<String, String?> ffmpegTags,
    required bool merge,
    required bool keepCachedVersionsIfDownloaded,
    required bool deleteOldFile,
    required void Function(int downloadedBytesLength) videoDownloadingStream,
    required void Function(int downloadedBytesLength) audioDownloadingStream,
    required void Function(int initialFileSize) onInitialVideoFileSize,
    required void Function(int initialFileSize) onInitialAudioFileSize,
    required Future<void> Function(File videoFile) onVideoFileReady,
    required Future<void> Function(File audioFile) onAudioFileReady,
    required Future<void> Function(File? deletedFile)? onOldFileDeleted,
  }) async {
    if (id.videoId.isEmpty) return null;

    String finalFilenameTemp = config.filename.filename;
    bool requiresRenaming = false;

    if (finalFilenameTemp.splitLast('.') != fileExtension) {
      finalFilenameTemp = "$finalFilenameTemp.$fileExtension";
      requiresRenaming = true;
    }

    final filenameCleanTemp = cleanupFilename(finalFilenameTemp);
    if (filenameCleanTemp != finalFilenameTemp) {
      finalFilenameTemp = filenameCleanTemp;
      requiresRenaming = true;
    }

    final finalFilenameWrapper = DownloadTaskFilename(initialFilename: finalFilenameTemp);

    if (requiresRenaming) {
      await renameConfigFilename(
        videoID: id,
        groupName: groupName,
        config: config,
        newFilename: finalFilenameWrapper,
        renameCacheFiles: false, // no worries we still gonna do the job.
      );
    }

    if (isDownloading.value[id] == null) {
      isDownloading.value[id] = <DownloadTaskFilename, bool>{}.obs;
      isDownloading.refresh();
    }
    isDownloading.value[id]![finalFilenameWrapper] = true;

    _startNotificationTimer();

    saveDirectory ??= Directory("${AppDirs.YOUTUBE_DOWNLOADS}${groupName.groupName}");
    await saveDirectory.create(recursive: true);

    if (deleteOldFile) {
      final file = File("${saveDirectory.path}/$finalFilenameTemp");
      try {
        if (await file.exists()) {
          await file.delete();
          onOldFileDeleted?.call(file);
        }
      } catch (_) {}
    }

    File? df;
    Future<bool> fileSizeQualified({
      required File file,
      required int targetSize,
      int allowanceBytes = 1024,
    }) async {
      try {
        final fileStats = await file.stat();
        final ok = fileStats.size >= targetSize - allowanceBytes; // it can be bigger cuz metadata and artwork may be added later
        return ok;
      } catch (_) {
        return false;
      }
    }

    File? videoFile;
    File? audioFile;

    bool isVideoFileCached = false;
    bool isAudioFileCached = false;

    bool skipAudio = false; // if video fails or stopped

    try {
      // --------- Downloading Choosen Video.
      if (videoStream != null) {
        final filecache = videoStream.getCachedFile(id.videoId);
        if (useCachedVersionsIfAvailable && filecache != null && await fileSizeQualified(file: filecache, targetSize: videoStream.sizeInBytes)) {
          videoFile = filecache;
          isVideoFileCached = true;
        } else {
          int bytesLength = 0;
          if (downloadsVideoProgressMap.value[id] == null) {
            downloadsVideoProgressMap.value[id] = <DownloadTaskFilename, DownloadProgress>{}.obs;
            downloadsVideoProgressMap.refresh();
          }
          final downloadedFile = await _checkFileAndDownload(
            groupName: groupName,
            url: videoStream.buildUrl() ?? '',
            targetSize: videoStream.sizeInBytes,
            filename: finalFilenameWrapper,
            destinationFilePath: _getTempVideoPath(
              groupName: groupName,
              fullFilename: finalFilenameWrapper,
              saveDir: saveDirectory,
            ),
            onInitialFileSize: (initialFileSize) {
              onInitialVideoFileSize(initialFileSize);
              bytesLength = initialFileSize;
            },
            downloadingStream: (downloadedBytesLength) {
              videoDownloadingStream(downloadedBytesLength);
              bytesLength += downloadedBytesLength;
              downloadsVideoProgressMap[id]![finalFilenameWrapper] = DownloadProgress(
                progress: bytesLength,
                totalProgress: videoStream.sizeInBytes,
              );
            },
          );
          videoFile = downloadedFile;
        }

        final qualified = await fileSizeQualified(file: videoFile, targetSize: videoStream.sizeInBytes);
        if (qualified) {
          await onVideoFileReady(videoFile);

          // if we should keep as a cache, we copy the downloaded file to cache dir
          // -- [!isVideoFileCached] is very important, otherwise it will copy to itself (0 bytes result).
          if (isVideoFileCached == false && keepCachedVersionsIfDownloaded) {
            await videoFile.copy(videoStream.cachePath(id.videoId));
          }
        } else {
          skipAudio = true;
          videoFile = null;
        }
      }
      // -----------------------------------

      // --------- Downloading Choosen Audio.
      if (skipAudio == false && audioStream != null) {
        final filecache = audioStream.getCachedFile(id.videoId);
        if (useCachedVersionsIfAvailable && filecache != null && await fileSizeQualified(file: filecache, targetSize: audioStream.sizeInBytes)) {
          audioFile = filecache;
          isAudioFileCached = true;
        } else {
          int bytesLength = 0;

          if (downloadsAudioProgressMap.value[id] == null) {
            downloadsAudioProgressMap.value[id] = <DownloadTaskFilename, DownloadProgress>{}.obs;
            downloadsAudioProgressMap.refresh();
          }
          final downloadedFile = await _checkFileAndDownload(
            groupName: groupName,
            url: audioStream.buildUrl() ?? '',
            targetSize: audioStream.sizeInBytes,
            filename: finalFilenameWrapper,
            destinationFilePath: _getTempAudioPath(
              groupName: groupName,
              fullFilename: finalFilenameWrapper,
              saveDir: saveDirectory,
            ),
            onInitialFileSize: (initialFileSize) {
              onInitialAudioFileSize(initialFileSize);
              bytesLength = initialFileSize;
            },
            downloadingStream: (downloadedBytesLength) {
              audioDownloadingStream(downloadedBytesLength);
              bytesLength += downloadedBytesLength;
              downloadsAudioProgressMap[id]![finalFilenameWrapper] = DownloadProgress(
                progress: bytesLength,
                totalProgress: audioStream.sizeInBytes,
              );
            },
          );
          audioFile = downloadedFile;
        }
        final qualified = await fileSizeQualified(file: audioFile, targetSize: audioStream.sizeInBytes);

        if (qualified) {
          await onAudioFileReady(audioFile);

          // if we should keep as a cache, we copy the downloaded file to cache dir
          // -- [!isAudioFileCached] is very important, otherwise it will copy to itself (0 bytes result).
          if (isAudioFileCached == false && keepCachedVersionsIfDownloaded) {
            await audioFile.copy(audioStream.cachePath(id.videoId));
          }
        } else {
          audioFile = null;
        }
      }
      // -----------------------------------

      // ----- merging if both video & audio were downloaded
      final output = "${saveDirectory.path}/${finalFilenameWrapper.filename}";
      if (merge && videoFile != null && audioFile != null) {
        bool didMerge = await NamidaFFMPEG.inst.mergeAudioAndVideo(
          videoPath: videoFile.path,
          audioPath: audioFile.path,
          outputPath: output,
        );
        if (!didMerge) {
          // -- sometimes, no extension is specified, which causes failure
          didMerge = await NamidaFFMPEG.inst.mergeAudioAndVideo(
            videoPath: videoFile.path,
            audioPath: audioFile.path,
            outputPath: "$output.mp4",
          );
        }
        if (didMerge) {
          Future.wait([
            if (isVideoFileCached == false) videoFile.tryDeleting(),
            if (isAudioFileCached == false) audioFile.tryDeleting(),
          ]); // deleting temp files since they got merged
        }
        if (await File(output).exists()) df = File(output);
      } else {
        // -- renaming files, or copying if cached
        Future<void> renameOrCopy({required File file, required String path, required bool isCachedVersion}) async {
          if (isCachedVersion) {
            await file.copy(path);
          } else {
            await file.rename(path);
          }
        }

        await Future.wait([
          if (videoFile != null && videoStream != null)
            renameOrCopy(
              file: videoFile,
              path: output,
              isCachedVersion: isVideoFileCached,
            ),
          if (audioFile != null && audioStream != null)
            renameOrCopy(
              file: audioFile,
              path: output,
              isCachedVersion: isAudioFileCached,
            ),
        ]);
        if (await File(output).exists()) df = File(output);
      }
    } catch (e) {
      printy('Error Downloading YT Video: $e', isError: true);
    }

    isDownloading[id]![finalFilenameWrapper] = false;

    final wasPaused = youtubeDownloadTasksInQueueMap[groupName]?[finalFilenameWrapper] == false;
    _doneDownloadingNotification(
      videoId: id,
      videoTitle: finalFilenameWrapper.filename,
      nameIdentifier: finalFilenameWrapper,
      filename: finalFilenameWrapper,
      downloadedFile: df,
      canceledByUser: wasPaused,
    );
    return df;
  }

  /// the file returned may not be complete if the client was closed.
  Future<File> _checkFileAndDownload({
    required String url,
    required int targetSize,
    required DownloadTaskGroupName groupName,
    required DownloadTaskFilename filename,
    required String destinationFilePath,
    required void Function(int initialFileSize) onInitialFileSize,
    required void Function(int downloadedBytesLength) downloadingStream,
  }) async {
    int downloadStartRange = 0;

    final file = await File(destinationFilePath).create(); // retrieving the temp file (or creating a new one).
    int initialFileSizeOnDisk = 0;
    try {
      initialFileSizeOnDisk = await file.length(); // fetching current size to be used as a range bytes for download request
    } catch (_) {}
    onInitialFileSize(initialFileSizeOnDisk);
    // only download if the download is incomplete, useful sometimes when file 'moving' fails.
    if (initialFileSizeOnDisk < targetSize) {
      downloadStartRange = initialFileSizeOnDisk;
      _downloadClientsMap[groupName] ??= {};

      _downloadManager.stopDownload(file: _downloadClientsMap[groupName]?[filename]);
      _downloadClientsMap[groupName]![filename] = file;
      await _downloadManager.download(
        url: url,
        file: file,
        downloadStartRange: downloadStartRange,
        downloadingStream: downloadingStream,
      );
    }
    _downloadManager.stopDownload(file: file);
    _downloadClientsMap[groupName]?.remove(filename);
    return File(destinationFilePath);
  }

  final _downloadManager = _YTDownloadManager();
  File? _latestSingleDownloadingFile;
  Future<NamidaVideo?> downloadYoutubeVideo({
    required String id,
    required VideoStream stream,
    required DateTime? creationDate,
    required void Function(List<VideoStream> availableStreams) onAvailableQualities,
    required void Function(VideoStream choosenStream) onChoosingQuality,
    required void Function(int downloadedBytesLength) downloadingStream,
    required void Function(int initialFileSize) onInitialFileSize,
    required bool Function() canStartDownloading,
  }) async {
    if (id == '') return null;
    NamidaVideo? dv;
    try {
      // --------- Getting Video to Download.
      VideoStream erabaretaStream = stream;

      onChoosingQuality(erabaretaStream);
      // ------------------------------------

      // --------- Downloading Choosen Video.
      String getVPath(bool isTemp) {
        final dir = isTemp ? AppDirs.VIDEOS_CACHE_TEMP : null;
        return erabaretaStream.cachePath(id, directory: dir);
      }

      final erabaretaStreamSizeInBytes = erabaretaStream.sizeInBytes;

      final file = await File(getVPath(true)).create(); // retrieving the temp file (or creating a new one).
      int initialFileSizeOnDisk = 0;
      try {
        initialFileSizeOnDisk = await file.length(); // fetching current size to be used as a range bytes for download request
      } catch (_) {}
      onInitialFileSize(initialFileSizeOnDisk);

      bool downloaded = false;
      final newFilePath = getVPath(false);
      if (initialFileSizeOnDisk >= erabaretaStreamSizeInBytes) {
        try {
          final movedFile = await file.move(
            newFilePath,
            goodBytesIfCopied: (newFileLength) async => (await file.length()) > newFileLength - 1024,
          );
          downloaded = movedFile != null;
        } catch (_) {}
      } else {
        // only download if the download is incomplete, useful sometimes when file 'moving' fails.
        if (!canStartDownloading()) return null;
        final downloadStartRange = initialFileSizeOnDisk;

        _downloadManager.stopDownload(file: _latestSingleDownloadingFile); // disposing old download process
        _latestSingleDownloadingFile = file;
        downloaded = await _downloadManager.download(
          url: erabaretaStream.buildUrl(),
          file: file,
          downloadStartRange: downloadStartRange,
          downloadingStream: downloadingStream,
          moveTo: newFilePath,
          moveToRequiredBytes: erabaretaStreamSizeInBytes,
        );
      }

      if (downloaded) {
        dv = NamidaVideo(
          path: newFilePath,
          ytID: id,
          nameInCache: newFilePath.getFilenameWOExt,
          height: erabaretaStream.height,
          width: erabaretaStream.width,
          sizeInBytes: erabaretaStreamSizeInBytes,
          frameratePrecise: erabaretaStream.fps.toDouble(),
          creationTimeMS: creationDate?.millisecondsSinceEpoch ?? 0,
          durationMS: erabaretaStream.duration.inMilliseconds,
          bitrate: erabaretaStream.bitrate,
        );
      }
    } catch (e) {
      printy('Error Downloading YT Video: $e', isError: true);
    }

    return dv;
  }

  void dispose({bool closeCurrentDownloadClient = true, bool closeAllClients = false}) {
    if (closeCurrentDownloadClient) {
      _downloadManager.stopDownload(file: _latestSingleDownloadingFile);
    }

    if (closeAllClients) {
      for (final c in _downloadClientsMap.values) {
        for (final file in c.values) {
          _downloadManager.stopDownload(file: file);
        }
      }
    }
  }
}

class _YTDownloadManager with PortsProvider<SendPort> {
  final _downloadCompleters = <String, Completer<bool>?>{}; // file path
  final _progressPorts = <String, ReceivePort?>{}; // file path

  /// if [file] is temp, u can provide [moveTo] to move/rename the temp file to it.
  Future<bool> download({
    required String? url,
    required File file,
    String? moveTo,
    int? moveToRequiredBytes,
    required int downloadStartRange,
    required void Function(int downloadedBytesLength) downloadingStream,
  }) async {
    if (url == null || url.isEmpty) return false;

    final filePath = file.path;
    _downloadCompleters[filePath]?.completeIfWasnt(false);
    _downloadCompleters[filePath] = Completer<bool>();

    _progressPorts[filePath]?.close();
    _progressPorts[filePath] = ReceivePort();
    final progressPort = _progressPorts[filePath]!;
    progressPort.listen((message) {
      downloadingStream(message as int);
    });
    final p = {
      'url': url,
      'filePath': filePath,
      'moveTo': moveTo,
      'moveToRequiredBytes': moveToRequiredBytes,
      'downloadStartRange': downloadStartRange,
      'progressPort': progressPort.sendPort,
    };
    await initialize();
    await sendPort(p);
    final res = await _downloadCompleters[filePath]?.future ?? false;
    _onFileFinish(filePath, null);
    return res;
  }

  Future<void> stopDownload({required File? file}) async {
    if (file == null) return;
    final filePath = file.path;
    _onFileFinish(filePath, false);
    final p = {
      'files': [file],
      'stop': true
    };
    await sendPort(p);
  }

  Future<void> stopDownloads({required List<File> files}) async {
    if (files.isEmpty) return;
    files.loop((e) => _onFileFinish(e.path, false));
    final p = {'files': files, 'stop': true};
    await sendPort(p);
  }

  static Future<void> _prepareDownloadResources(SendPort sendPort) async {
    final recievePort = ReceivePort();
    sendPort.send(recievePort.sendPort);

    final requesters = <String, HttpClientWrapper?>{}; // filePath

    StreamSubscription? streamSub;
    streamSub = recievePort.listen((p) async {
      if (PortsProvider.isDisposeMessage(p)) {
        for (final requester in requesters.values) {
          requester?.close();
        }
        requesters.clear();
        recievePort.close();
        streamSub?.cancel();
        return;
      } else {
        p as Map;
        final stop = p['stop'] as bool?;
        if (stop == true) {
          final files = p['files'] as List<File>?;
          if (files != null) {
            for (final file in files) {
              final path = file.path;
              requesters[path]?.close();
              requesters[path] = null;
            }
          }
        } else {
          final filePath = p['filePath'] as String;
          final url = p['url'] as String;
          final downloadStartRange = p['downloadStartRange'] as int;
          final moveTo = p['moveTo'] as String?;
          final moveToRequiredBytes = p['moveToRequiredBytes'] as int?;
          final progressPort = p['progressPort'] as SendPort;

          requesters[filePath] = HttpClientWrapper();
          final file = File(filePath);
          file.createSync(recursive: true);
          final fileStream = file.openWrite(mode: FileMode.append);

          final requester = requesters[filePath];
          if (requester == null) return; // always non null tho
          try {
            final headers = {'range': 'bytes=$downloadStartRange-'};
            final response = await requester.getUrlWithHeaders(Uri.parse(url), headers);
            final downloadStream = response.asBroadcastStream();

            await for (final data in downloadStream) {
              fileStream.add(data);
              progressPort.send(data.length);
            }
            bool? movedSuccessfully;
            if (moveTo != null && moveToRequiredBytes != null) {
              try {
                final fileStats = file.statSync();
                const allowance = 1024; // 1KB allowance
                if (fileStats.size >= moveToRequiredBytes - allowance) {
                  final movedFile = file.moveSync(
                    moveTo,
                    goodBytesIfCopied: (fileLength) => fileLength >= moveToRequiredBytes - allowance,
                  );
                  if (movedFile == null) movedSuccessfully = false;
                }
              } catch (_) {}
            }
            return sendPort.send(MapEntry(filePath, movedSuccessfully ?? true));
          } catch (_) {
            // client force closed
            return sendPort.send(MapEntry(filePath, false));
          } finally {
            try {
              final req = requesters.remove(filePath);
              await req?.close();
            } catch (_) {}
            try {
              await fileStream.flush();
              await fileStream.close(); // closing file.
            } catch (_) {}
          }
        }
      }
    });

    sendPort.send(null); // prepared
  }

  @override
  void onResult(dynamic result) {
    if (result is MapEntry) {
      _onFileFinish(result.key, result.value);
    }
  }

  @override
  IsolateFunctionReturnBuild<SendPort> isolateFunction(SendPort port) {
    return IsolateFunctionReturnBuild(_prepareDownloadResources, port);
  }

  void _onFileFinish(String path, bool? value) {
    if (value != null) _downloadCompleters[path]?.completeIfWasnt(value);
    _downloadCompleters[path] = null;
    _progressPorts[path]?.close();
    _progressPorts[path] = null;
  }
}
