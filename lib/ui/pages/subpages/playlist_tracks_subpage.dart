import 'package:flutter/material.dart';

import 'package:get/get.dart';

import 'package:namida/class/playlist.dart';
import 'package:namida/controller/playlist_controller.dart';
import 'package:namida/core/constants.dart';
import 'package:namida/core/extensions.dart';
import 'package:namida/core/functions.dart';
import 'package:namida/core/icon_fonts/broken_icons.dart';
import 'package:namida/core/translations/strings.dart';
import 'package:namida/main_page.dart';
import 'package:namida/ui/widgets/custom_widgets.dart';
import 'package:namida/ui/dialogs/common_dialogs.dart';
import 'package:namida/ui/widgets/library/multi_artwork_container.dart';
import 'package:namida/ui/widgets/library/track_tile.dart';

class PlaylisTracksPage extends StatelessWidget {
  final Playlist playlist;
  final bool disableAnimation;
  final ScrollController? scrollController;
  final int? indexToHighlight;
  PlaylisTracksPage({super.key, required this.playlist, this.disableAnimation = false, this.scrollController, this.indexToHighlight});

  final RxBool shouldReorder = false.obs;

  final ScrollController defController = ScrollController();

  @override
  Widget build(BuildContext context) {
    final finalScrollController = scrollController ?? defController;
    final isMostPlayedPlaylist = playlist.name == k_PLAYLIST_NAME_MOST_PLAYED;
    final isHistoryPlaylist = playlist.name == k_PLAYLIST_NAME_HISTORY;
    return MainPageWrapper(
      actionsToAdd: [
        if (!isMostPlayedPlaylist && !isHistoryPlaylist)
          Obx(
            () => Tooltip(
              message: shouldReorder.value ? Language.inst.DISABLE_REORDERING : Language.inst.ENABLE_REORDERING,
              child: NamidaIconButton(
                icon: shouldReorder.value ? Broken.forward_item : Broken.lock_1,
                padding: const EdgeInsets.only(right: 14, left: 4.0),
                onPressed: () => shouldReorder.value = !shouldReorder.value,
              ),
            ),
          ),
        NamidaIconButton(
          icon: Broken.more_2,
          padding: const EdgeInsets.only(right: 14, left: 4.0),
          onPressed: () => NamidaDialogs.inst.showPlaylistDialog(playlist),
        ),
      ],
      child: Obx(
        () {
          final rxplaylist = PlaylistController.inst.defaultPlaylists.firstWhereOrNull((element) => element == playlist) ??
              PlaylistController.inst.playlistList.firstWhere((element) => element == playlist);
          final finalTracks = isMostPlayedPlaylist ? PlaylistController.inst.topTracksMap.keys.toList() : rxplaylist.tracks.map((e) => e.track).toList();
          final topContainer = SubpagesTopContainer(
            title: rxplaylist.name.translatePlaylistName,
            subtitle: [finalTracks.displayTrackKeyword, rxplaylist.date.dateFormatted].join(' - '),
            thirdLineText: rxplaylist.modes.isNotEmpty ? rxplaylist.modes.join(', ') : '',
            imageWidget: MultiArtworkContainer(
              heroTag: 'playlist_artwork_${rxplaylist.name}',
              size: Get.width * 0.35,
              tracks: finalTracks,
            ),
            tracks: finalTracks,
          );

          /// Top Music Playlist
          return isMostPlayedPlaylist
              ? NamidaTracksList(
                  queueLength: PlaylistController.inst.topTracksMap.length,
                  scrollController: finalScrollController,
                  header: topContainer,
                  buildDefaultDragHandles: false,
                  onReorder: (oldIndex, newIndex) {},
                  padding: const EdgeInsets.only(bottom: kBottomPadding),
                  itemBuilder: (context, i) {
                    final track = PlaylistController.inst.topTracksMap.keys.elementAt(i);
                    final count = PlaylistController.inst.topTracksMap.values.elementAt(i);
                    final w = TrackTile(
                      draggableThumbnail: false,
                      index: i,
                      track: track,
                      queue: PlaylistController.inst.topTracksMap.keys.toList(),
                      playlist: rxplaylist,
                      canHaveDuplicates: true,
                      bgColor: i == indexToHighlight ? context.theme.colorScheme.onBackground.withAlpha(40) : null,
                      trailingWidget: Container(
                        padding: const EdgeInsets.all(6.0),
                        decoration: BoxDecoration(
                          color: context.theme.scaffoldBackgroundColor,
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          count.toString(),
                          style: context.textTheme.displaySmall,
                        ),
                      ),
                    );
                    if (disableAnimation) return w;
                    return AnimatingTile(key: ValueKey(i), position: i, child: w);
                  },
                )
              :

              /// Normal Tracks
              NamidaTracksList(
                  scrollController: finalScrollController,
                  header: topContainer,
                  buildDefaultDragHandles: shouldReorder.value,
                  padding: const EdgeInsets.only(bottom: kBottomPadding),
                  onReorder: (oldIndex, newIndex) {
                    if (newIndex > oldIndex) {
                      newIndex -= 1;
                    }
                    final item = rxplaylist.tracks.elementAt(oldIndex);
                    PlaylistController.inst.removeTrackFromPlaylist(rxplaylist.name, oldIndex);
                    PlaylistController.inst.insertTracksInPlaylist(rxplaylist.name, [item], newIndex);
                  },
                  queueLength: rxplaylist.tracks.length,
                  itemBuilder: (context, i) {
                    final track = rxplaylist.tracks[i];
                    final w = FadeDismissible(
                      key: Key("Diss_$i${track.track.path}"),
                      direction: shouldReorder.value ? DismissDirection.horizontal : DismissDirection.none,
                      onDismissed: (direction) => NamidaOnTaps.inst.onRemoveTrackFromPlaylist(i, rxplaylist),
                      child: Stack(
                        alignment: Alignment.centerLeft,
                        children: [
                          TrackTile(
                            index: i,
                            track: track.track,
                            queue: rxplaylist.tracks.map((e) => e.track).toList(),
                            playlist: rxplaylist,
                            canHaveDuplicates: true,
                            draggableThumbnail: shouldReorder.value,
                            bgColor: i == indexToHighlight ? context.theme.colorScheme.onBackground.withAlpha(40) : null,
                            thirdLineText: isHistoryPlaylist ? track.dateAdded.dateAndClockFormattedOriginal : '',
                          ),
                          Obx(() => ThreeLineSmallContainers(enabled: shouldReorder.value)),
                        ],
                      ),
                    );
                    if (disableAnimation) return w;
                    return AnimatingTile(key: ValueKey(i), position: i, child: w);
                  },
                );
        },
      ),
    );
  }
}

class ThreeLineSmallContainers extends StatelessWidget {
  final bool enabled;
  const ThreeLineSmallContainers({Key? key, required this.enabled}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List<Widget>.generate(
        3,
        (index) => AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.bounceIn,
          width: enabled ? 9.0 : 2.0,
          height: 1.2,
          margin: const EdgeInsets.symmetric(vertical: 1),
          color: context.theme.listTileTheme.iconColor?.withAlpha(120),
        ),
      ),
    );
  }
}
