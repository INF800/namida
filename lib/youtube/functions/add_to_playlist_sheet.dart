import 'dart:async';

import 'package:flutter/material.dart';

import 'package:youtipie/class/playlist_for_video.dart';
import 'package:youtipie/class/youtipie_feed/playlist_info_item_user.dart';
import 'package:youtipie/core/enum.dart';
import 'package:youtipie/youtipie.dart';

import 'package:namida/base/pull_to_refresh.dart';
import 'package:namida/controller/current_color.dart';
import 'package:namida/controller/navigator_controller.dart';
import 'package:namida/controller/settings_controller.dart';
import 'package:namida/core/enums.dart';
import 'package:namida/core/extensions.dart';
import 'package:namida/core/functions.dart';
import 'package:namida/core/icon_fonts/broken_icons.dart';
import 'package:namida/core/namida_converter_ext.dart';
import 'package:namida/core/translations/language.dart';
import 'package:namida/core/utils.dart';
import 'package:namida/main.dart';
import 'package:namida/ui/widgets/custom_widgets.dart';
import 'package:namida/youtube/controller/youtube_info_controller.dart';
import 'package:namida/youtube/controller/youtube_playlist_controller.dart' as pc;
import 'package:namida/youtube/widgets/yt_thumbnail.dart';
import 'package:namida/youtube/youtube_playlists_view.dart';

void showAddToPlaylistSheet({
  BuildContext? ctx,
  required Iterable<String> ids,
  required Map<String, String?> idsNamesLookup,
  String playlistNameToAdd = '',
}) async {
  final context = ctx ?? rootContext;

  final videoNamesSubtitle = ids
          .map((id) => idsNamesLookup[id] ?? YoutubeInfoController.utils.getVideoName(id) ?? id) //
          .take(3)
          .join(', ') +
      (ids.length > 3 ? '... + ${ids.length - 3}' : '');

  await Future.delayed(Duration.zero); // delay bcz sometimes doesnt show
  await showModalBottomSheet(
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    // ignore: use_build_context_synchronously
    context: context,
    builder: (context) {
      final bottomPadding = MediaQuery.viewInsetsOf(context).bottom + MediaQuery.paddingOf(context).bottom;
      return Container(
        height: context.height * 0.65 + bottomPadding,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24.0.multipliedRadius),
          color: context.theme.scaffoldBackgroundColor,
        ),
        margin: const EdgeInsets.all(8.0),
        padding: EdgeInsets.only(bottom: bottomPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 24.0),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24.0),
              child: Text(
                lang.ADD_TO_PLAYLIST,
                style: context.textTheme.displayLarge,
              ),
            ),
            const SizedBox(height: 6.0),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24.0),
              child: playlistNameToAdd == ''
                  ? Text(
                      videoNamesSubtitle,
                      style: context.textTheme.displaySmall,
                    )
                  : Text.rich(
                      TextSpan(
                        text: playlistNameToAdd,
                        style: context.textTheme.displayMedium?.copyWith(fontWeight: FontWeight.w600),
                        children: [
                          TextSpan(
                            text: " ($videoNamesSubtitle)",
                            style: context.textTheme.displaySmall,
                          ),
                        ],
                      ),
                    ),
            ),
            const SizedBox(height: 6.0),
            Expanded(
              child: NamidaTabView(
                initialIndex: settings.youtube.addToPlaylistsTabIndex,
                onIndexChanged: (index) {
                  settings.youtube.save(addToPlaylistsTabIndex: index);
                },
                tabs: [lang.LOCAL, lang.YOUTUBE],
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.max,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: YoutubePlaylistsView(idsToAdd: ids, displayMenu: false),
                      ),
                      const SizedBox(height: 6.0),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          const SizedBox(width: 18.0),
                          Expanded(
                            child: NamidaInkWell(
                              bgColor: CurrentColor.inst.color.withAlpha(40),
                              height: 48.0,
                              borderRadius: 12.0,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Broken.add),
                                  const SizedBox(width: 8.0),
                                  Text(
                                    lang.CREATE,
                                    style: context.textTheme.displayMedium,
                                  ),
                                ],
                              ),
                              onTap: () async {
                                final text = await showNamidaBottomSheetWithTextField(
                                  context: context,
                                  title: lang.CONFIGURE,
                                  initalControllerText: '',
                                  hintText: '',
                                  labelText: lang.NAME,
                                  validator: (value) => pc.YoutubePlaylistController.inst.validatePlaylistName(value),
                                  buttonText: lang.ADD,
                                  onButtonTap: (text) => true,
                                );
                                if (text != null) pc.YoutubePlaylistController.inst.addNewPlaylist(text);
                              },
                            ),
                          ),
                          const SizedBox(width: 12.0),
                          Obx(
                            () {
                              const watchLater = 'Watch Later';
                              pc.YoutubePlaylistController.inst.playlistsMap.valueR;
                              final pl = pc.YoutubePlaylistController.inst.getPlaylist(watchLater);
                              final idExist = pl?.tracks.firstWhereEff((e) => e.id == ids.firstOrNull) != null;
                              return NamidaIconButton(
                                tooltip: () => watchLater,
                                icon: Broken.clock,
                                child: idExist ? const StackedIcon(baseIcon: Broken.clock, secondaryIcon: Broken.tick_circle) : null,
                                onPressed: () {
                                  final pl = pc.YoutubePlaylistController.inst.getPlaylist(watchLater);
                                  if (pl == null) {
                                    pc.YoutubePlaylistController.inst.addNewPlaylist(watchLater, videoIds: ids);
                                  } else if (pl.tracks.firstWhereEff((e) => e.id == ids.firstOrNull) == null) {
                                    pc.YoutubePlaylistController.inst.addTracksToPlaylist(pl, ids);
                                  }
                                },
                              );
                            },
                          ),
                          const SizedBox(width: 18.0),
                        ],
                      ),
                    ],
                  ),
                  _PlaylistsForVideoPage(videoIds: ids),
                ],
              ),
            ),
            const SizedBox(height: 18.0),
          ],
        ),
      );
    },
  );
}

class _PlaylistsForVideoPage extends StatefulWidget {
  final Iterable<String> videoIds;
  const _PlaylistsForVideoPage({required this.videoIds});

  @override
  State<_PlaylistsForVideoPage> createState() => __PlaylistsForVideoPageState();
}

class __PlaylistsForVideoPageState extends State<_PlaylistsForVideoPage> {
  List<PlaylistForVideoItem>? _allPlaylists;
  List<PlaylistForVideoItem>? _createdPlaylists;
  late final _playlistsLookup = <String, PlaylistInfoItemUser>{};
  late final _newContainsVideo = <String, bool>{};

  late final isSingle = () {
    int count = 0;
    for (final _ in widget.videoIds) {
      count++;
      if (count > 1) return false;
    }
    return true;
  }();
  late final firstVideoId = widget.videoIds.first;
  late final videosList = () {
    final idsList = <String>[];
    final addedAlr = <String, bool>{};
    for (final id in widget.videoIds) {
      if (addedAlr[id] == true) {
        // -- added
      } else {
        idsList.add(id);
        addedAlr[id] = true;
      }
    }
    return idsList;
  }();

  Future<bool> _confirmRemoveVideos() async {
    bool confirmed = false;
    await NamidaNavigator.inst.navigateDialog(
      dialog: CustomBlurryDialog(
        isWarning: true,
        normalTitleStyle: true,
        bodyText: lang.CONFIRM,
        actions: [
          const CancelButton(),
          NamidaButton(
            text: lang.REMOVE.toUpperCase(),
            onPressed: () async {
              NamidaNavigator.inst.closeDialog();
              confirmed = true;
            },
          ),
        ],
      ),
    );
    return confirmed;
  }

  Future<void> _onAddToPlaylistTap(PlaylistForVideoItem playlist, void Function() onStart, void Function() onEnd) async {
    onStart();
    final done = await YoutiPie.playlistAction.addRemoveVideosInPlaylist(
      videosToAdd: videosList,
      videosToRemove: null,
      playlistId: playlist.playlistId,
    );
    onEnd();
    if (done) {
      if (mounted) {
        setState(() {
          _newContainsVideo[playlist.playlistId] = true;
        });
      }
    }
  }

  Future<void> _onRemoveFromPlaylistTap(PlaylistForVideoItem playlist, void Function() onStart, void Function() onEnd) async {
    onStart();
    final done = await YoutiPie.playlistAction.addRemoveVideosInPlaylist(
      videosToAdd: null,
      videosToRemove: videosList,
      playlistId: playlist.playlistId,
    );
    onEnd();
    if (done) {
      if (mounted) {
        setState(() {
          _newContainsVideo[playlist.playlistId] = false;
        });
      }
    }
  }

  Future<void> _onPlaylistTap(PlaylistForVideoItem pl, void Function() onStart, void Function() onEnd) async {
    if (isSingle) {
      if ((_newContainsVideo[pl.playlistId] ?? pl.containsVideo) == true) {
        _onRemoveFromPlaylistTap(pl, onStart, onEnd);
      } else {
        _onAddToPlaylistTap(pl, onStart, onEnd);
      }
    } else {
      if (_newContainsVideo[pl.playlistId] == true) {
        // -- already added all videos
        final confirmed = await _confirmRemoveVideos();
        if (confirmed) {
          _onRemoveFromPlaylistTap(pl, onStart, onEnd);
        }
      } else {
        final action = await NamidaOnTaps.inst
            .showDuplicatedDialogAction([PlaylistAddDuplicateAction.addAllAndRemoveOldOnes, PlaylistAddDuplicateAction.justAddEverything], displayTitle: false);
        if (action == PlaylistAddDuplicateAction.justAddEverything) {
          await _onAddToPlaylistTap(pl, onStart, onEnd);
        } else if (action == PlaylistAddDuplicateAction.addAllAndRemoveOldOnes) {
          await _onRemoveFromPlaylistTap(pl, onStart, () {});
          await _onAddToPlaylistTap(pl, () {}, onEnd);
        }
      }
    }
  }

  Future<void> _fetchPlaylistsForVideo(String videoId) async {
    final res = await YoutiPie.userplaylist.getPlaylistsForVideo(
      videoId: videoId,
      insertActiveAtTop: true,
    );
    if (res != null && mounted) {
      setState(() => _allPlaylists = res);
    }
  }

  Future<void> _fetchNormalPlaylistsResult() async {
    final res = await YoutiPie.userplaylist.getUserPlaylists();
    if (res != null && mounted) {
      setState(() {
        res.items.loop((item) => _playlistsLookup[item.id] = item);
      });
    }
  }

  @override
  void initState() {
    _fetchPlaylistsForVideo(firstVideoId);
    _fetchNormalPlaylistsResult();
    super.initState();
  }

  Widget? _itemBuilder(BuildContext context, PlaylistForVideoItem pl) {
    final title = pl.playlistTitle ?? '?';
    final subtitle = pl.privacy?.toText();
    final info = _playlistsLookup[pl.playlistId];
    bool showBorder = false;
    if (isSingle) {
      showBorder = (_newContainsVideo[pl.playlistId] ?? pl.containsVideo) == true;
    } else {
      showBorder = _newContainsVideo[pl.playlistId] == true;
    }
    return NamidaLoadingSwitcher(
      showLoading: false,
      builder: (startLoading, stopLoading, isLoading) => NamidaInkWell(
        animationDurationMS: 200,
        margin: const EdgeInsets.symmetric(vertical: 4.0),
        width: context.width,
        bgColor: context.theme.cardColor,
        decoration: BoxDecoration(
          border: showBorder
              ? Border(
                  left: BorderSide(
                    width: 2.0,
                    color: context.theme.colorScheme.secondary.withOpacity(0.5),
                  ),
                  bottom: BorderSide(
                    width: 2.0,
                    color: context.theme.colorScheme.secondary.withOpacity(0.5),
                  ),
                )
              : null,
        ),
        onTap: isLoading ? null : () => _onPlaylistTap(pl, startLoading, stopLoading),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0),
          child: Row(
            children: [
              const SizedBox(width: 8.0),
              YoutubeThumbnail(
                key: Key(pl.playlistId),
                borderRadius: 8.0,
                width: 64.0,
                height: 64.0 * 9 / 16,
                customUrl: info?.thumbnails.pick()?.url,
                isImportantInCache: false,
                type: ThumbnailType.playlist,
                forceSquared: false,
              ),
              const SizedBox(width: 12.0),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: context.textTheme.displayMedium,
                    ),
                    if (subtitle != null && subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        style: context.textTheme.displaySmall,
                      ),
                  ],
                ),
              ),
              if (info?.videosCount != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4.0),
                  child: Text(
                    info!.videosCount!.formatDecimal(),
                    style: context.textTheme.displaySmall,
                  ),
                ),
              SizedBox(
                width: 22.0,
                height: 22.0,
                child: isLoading
                    ? const Padding(
                        padding: EdgeInsets.all(2.0),
                        child: CircularProgressIndicator(strokeWidth: 2.0),
                      )
                    : isSingle
                        ? Padding(
                            padding: const EdgeInsets.all(2.0),
                            child: Checkbox.adaptive(
                              value: _newContainsVideo[pl.playlistId] ?? pl.containsVideo,
                              onChanged: (value) => _onPlaylistTap(pl, startLoading, stopLoading),
                            ),
                          )
                        : _newContainsVideo[pl.playlistId] == true
                            ? const Icon(
                                Broken.tick_circle,
                                size: 22.0,
                              )
                            : const Icon(
                                Broken.add_circle,
                                size: 22.0,
                              ),
              ),
              const SizedBox(width: 12.0),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final allPlaylists = _allPlaylists;
    final createdPlaylists = _createdPlaylists;

    return Column(
      children: [
        Expanded(
          child: NamidaScrollbarWithController(
            child: (c) => PullToRefresh(
              controller: c,
              onRefresh: () => _fetchPlaylistsForVideo(firstVideoId),
              maxDistance: 64.0,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                child: CustomScrollView(
                  controller: c,
                  slivers: [
                    const SliverPadding(
                      padding: EdgeInsets.only(top: 12.0),
                    ),
                    if (createdPlaylists != null)
                      SliverList.builder(
                        itemCount: createdPlaylists.length,
                        itemBuilder: (context, index) {
                          return _itemBuilder(context, createdPlaylists[index]);
                        },
                      ),
                    allPlaylists == null
                        ? SliverToBoxAdapter(
                            child: ShimmerWrapper(
                              transparent: false,
                              shimmerEnabled: true,
                              child: ListView.builder(
                                padding: EdgeInsets.zero,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: 10,
                                shrinkWrap: true,
                                itemBuilder: (context, index) {
                                  return NamidaInkWell(
                                    animationDurationMS: 200,
                                    margin: const EdgeInsets.symmetric(vertical: 4.0),
                                    height: 52.0,
                                    bgColor: context.theme.cardColor,
                                  );
                                },
                              ),
                            ),
                          )
                        : SliverList.builder(
                            itemCount: allPlaylists.length,
                            itemBuilder: (context, index) {
                              return _itemBuilder(context, allPlaylists[index]);
                            },
                          ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12.0),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            const SizedBox(width: 18.0),
            Expanded(
              child: NamidaInkWell(
                bgColor: CurrentColor.inst.color.withAlpha(40),
                height: 48.0,
                borderRadius: 12.0,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Broken.add),
                    const SizedBox(width: 8.0),
                    Text(
                      lang.CREATE,
                      style: context.textTheme.displayMedium,
                    ),
                  ],
                ),
                onTap: () async {
                  final privacyIconsLookup = {
                    PlaylistPrivacy.public: Broken.global,
                    PlaylistPrivacy.unlisted: Broken.link,
                    PlaylistPrivacy.private: Broken.lock_1,
                  };
                  final privacyRx = PlaylistPrivacy.private.obs;
                  const addAsInitial = true;
                  await showNamidaBottomSheetWithTextField(
                    context: context,
                    title: lang.CONFIGURE,
                    initalControllerText: '',
                    hintText: '',
                    maxLength: YoutubeInfoController.userplaylist.MAX_PLAYLIST_NAME,
                    labelText: lang.NAME,
                    extraItemsBuilder: (formState) => Column(
                      children: [
                        const SizedBox(height: 12.0),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: ObxO(
                            rx: privacyRx,
                            builder: (privacy) => Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: PlaylistPrivacy.values.map(
                                (e) {
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 4.0),
                                    child: NamidaInkWellButton(
                                      icon: privacyIconsLookup[e],
                                      text: e.toText(),
                                      bgColor: context.theme.colorScheme.secondaryContainer.withOpacity(privacy == e ? 0.5 : 0.2),
                                      onTap: () => privacyRx.value = e,
                                      trailing: const SizedBox(
                                        width: 16.0,
                                        height: 16.0,
                                        child: Checkbox.adaptive(
                                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.all(Radius.circular(6.0)),
                                          ),
                                          value: true,
                                          onChanged: null,
                                        ),
                                      ).animateEntrance(
                                        showWhen: privacy == e,
                                        allCurves: Curves.fastLinearToSlowEaseIn,
                                        durationMS: 300,
                                      ),
                                    ),
                                  );
                                },
                              ).toList(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    validator: (value) {
                      if (value == null || value.isEmpty) return lang.PLEASE_ENTER_A_NAME;
                      return YoutubeInfoController.userplaylist.validatePlaylistTitle(value);
                    },
                    buttonText: lang.ADD,
                    onButtonTap: (text) async {
                      if (text.isEmpty) return false;

                      final playlistTitle = text;
                      final newPlaylistId = await YoutubeInfoController.userplaylist.createPlaylist(
                        title: playlistTitle,
                        // ignore: dead_code
                        initialVideoIds: addAsInitial ? videosList : [],
                        privacy: privacyRx.value,
                      );
                      if (newPlaylistId != null) {
                        if (mounted) {
                          setState(() {
                            _createdPlaylists ??= [];
                            _createdPlaylists!.add(
                              PlaylistForVideoItem(
                                playlistId: newPlaylistId,
                                playlistTitle: playlistTitle,
                                privacy: privacyRx.value,
                                containsVideo: addAsInitial,
                              ),
                            );
                          });
                        }

                        return true;
                      }
                      return false;
                    },
                  );
                  Future.delayed(const Duration(microseconds: 300), () {
                    privacyRx.close();
                  });
                },
              ),
            ),
            const SizedBox(width: 18.0),
          ],
        ),
      ],
    );
  }
}
