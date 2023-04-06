import 'package:flutter/material.dart';

import 'package:get/get.dart';

import 'package:namida/class/track.dart';
import 'package:namida/controller/settings_controller.dart';
import 'package:namida/core/extensions.dart';
import 'package:namida/core/functions.dart';
import 'package:namida/ui/widgets/artwork.dart';
import 'package:namida/ui/widgets/custom_widgets.dart';
import 'package:namida/ui/dialogs/common_dialogs.dart';

class AlbumTile extends StatelessWidget {
  final List<Track> album;

  const AlbumTile({
    super.key,
    required this.album,
  });

  @override
  Widget build(BuildContext context) {
    final albumthumnailSize = SettingsController.inst.albumThumbnailSizeinList.value;
    final albumTileHeight = SettingsController.inst.albumListTileHeight.value;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3.0, horizontal: 8.0),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular((0.2 * albumTileHeight).multipliedRadius),
        boxShadow: [
          BoxShadow(
            color: context.theme.shadowColor.withAlpha(20),
            blurRadius: 12.0,
            offset: const Offset(0, 2),
          )
        ],
      ),
      child: Material(
        color: context.theme.cardColor,
        child: InkWell(
          highlightColor: const Color.fromARGB(60, 120, 120, 120),
          onLongPress: () => NamidaDialogs.inst.showAlbumDialog(album),
          onTap: () => NamidaOnTaps.inst.onAlbumTap(album[0].album),
          child: Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.only(top: 3.0, bottom: 3.0, right: 8.0),
            height: albumTileHeight + 14,
            child: Row(
              children: [
                Hero(
                  tag: 'parent_album_artwork_${album[0].album}',
                  child: Container(
                    margin: const EdgeInsets.symmetric(
                      horizontal: 12.0,
                    ),
                    width: albumthumnailSize,
                    height: albumthumnailSize,
                    child: ArtworkWidget(
                      thumnailSize: albumthumnailSize,
                      path: album[0].pathToImage,
                      forceSquared: SettingsController.inst.forceSquaredAlbumThumbnail.value,
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        album[0].album,
                        style: context.textTheme.displayMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (album[0].albumArtist != '')
                        Text(
                          album[0].albumArtist,
                          style: context.textTheme.displaySmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      Text(
                        [
                          album.displayTrackKeyword,
                          album[0].year.yearFormatted,
                        ].join(' • '),
                        style: context.textTheme.displaySmall?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Text(
                  [
                    album.totalDurationFormatted,
                  ].join(' - '),
                  style: context.textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(width: 4.0),
                MoreIcon(
                  padding: 6.0,
                  onPressed: () => NamidaDialogs.inst.showAlbumDialog(album),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
