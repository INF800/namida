import 'dart:async';
import 'dart:io';

import 'package:get/get.dart';

import 'package:namida/class/playlist.dart';
import 'package:namida/class/track.dart';
import 'package:namida/controller/generators_controller.dart';
import 'package:namida/controller/history_controller.dart';
import 'package:namida/controller/navigator_controller.dart';
import 'package:namida/controller/search_sort_controller.dart';
import 'package:namida/core/constants.dart';
import 'package:namida/core/enums.dart';
import 'package:namida/core/extensions.dart';
import 'package:namida/core/translations/language.dart';

class PlaylistController {
  static PlaylistController get inst => _instance;
  static final PlaylistController _instance = PlaylistController._internal();
  PlaylistController._internal();

  Playlist? getPlaylist(String name) => name == k_PLAYLIST_NAME_FAV ? favouritesPlaylist.value : playlistsMap[name];

  final RxMap<String, Playlist> playlistsMap = <String, Playlist>{}.obs;

  final Rx<Playlist> favouritesPlaylist = Playlist(
    name: k_PLAYLIST_NAME_FAV,
    tracks: [],
    creationDate: currentTimeMS,
    modifiedDate: currentTimeMS,
    comment: '',
    moods: [],
    isFav: true,
  ).obs;

  final RxBool canReorderTracks = false.obs;

  void addNewPlaylist(
    String name, {
    List<Track> tracks = const <Track>[],
    List<Track> tracksToAdd = const <Track>[],
    int? creationDate,
    String comment = '',
    List<String> moods = const [],
  }) async {
    assert(!isOneOfDefaultPlaylists(name), kUnsupportedOperationMessage);

    creationDate ??= currentTimeMS;

    final pl = Playlist(
      name: name,
      tracks: tracks.mapped((e) => TrackWithDate(
            dateAdded: currentTimeMS,
            track: e,
            source: TrackSource.local,
          )),
      creationDate: creationDate,
      modifiedDate: currentTimeMS,
      comment: comment,
      moods: moods,
      isFav: false,
    );
    _updateMap(pl);

    await _savePlaylistToStorage(pl);
  }

  Future<void> reAddPlaylist(Playlist playlist, int modifiedDate) async {
    final newPlaylist = playlist.copyWith(modifiedDate: modifiedDate);
    _updateMap(newPlaylist);
    _sortPlaylists();
    await _savePlaylistToStorage(playlist);
  }

  Future<void> removePlaylist(Playlist playlist) async {
    // navigate back in case the current route is this playlist
    final lastPage = NamidaNavigator.inst.currentRoute;
    if (lastPage?.route == RouteType.SUBPAGE_playlistTracks) {
      if (lastPage?.name == playlist.name) {
        NamidaNavigator.inst.popPage();
      }
    }
    _removeFromMap(playlist);
    // resorting to rebuild ui without the playlist.
    SearchSortController.inst.sortMedia(MediaType.playlist);

    await _deletePlaylistFromStorage(playlist);
  }

  /// returns true if succeeded.
  Future<bool> updatePropertyInPlaylist(
    String oldPlaylistName, {
    int? creationDate,
    String? comment,
    bool? isFav,
    List<String>? moods,
  }) async {
    assert(!isOneOfDefaultPlaylists(oldPlaylistName), kUnsupportedOperationMessage);

    final oldPlaylist = getPlaylist(oldPlaylistName);
    if (oldPlaylist == null) return false;

    final newpl = oldPlaylist.copyWith(creationDate: creationDate, comment: comment, isFav: isFav, moods: moods);
    _updateMap(newpl, oldPlaylistName);
    await _savePlaylistToStorage(newpl);
    return true;
  }

  /// returns true if succeeded.
  Future<bool> renamePlaylist(String playlistName, String newName) async {
    try {
      await File('${AppDirs.PLAYLISTS}/$playlistName.json').rename('${AppDirs.PLAYLISTS}/$newName.json');
    } catch (e) {
      printy(e, isError: true);
      return false;
    }
    final playlist = getPlaylist(playlistName);
    if (playlist == null) return false;

    final newPlaylist = playlist.copyWith(name: newName, modifiedDate: currentTimeMS);
    _updateMap(newPlaylist, playlistName);

    return (await _savePlaylistToStorage(newPlaylist));
  }

  String? validatePlaylistName(String? value) {
    value ??= '';

    if (value.isEmpty) {
      return Language.inst.PLEASE_ENTER_A_NAME;
    }
    if (isOneOfDefaultPlaylists(value)) {
      return Language.inst.PLEASE_ENTER_A_NAME;
    }

    final illegalChar = Platform.pathSeparator;
    if (value.contains(illegalChar)) {
      return "${Language.inst.NAME_CONTAINS_BAD_CHARACTER} $illegalChar";
    }

    if (playlistsMap.keyExists(value) || File('${AppDirs.PLAYLISTS}/$value.json').existsSync()) {
      return Language.inst.PLEASE_ENTER_A_DIFFERENT_NAME;
    }
    return null;
  }

  void addTracksToPlaylist(Playlist playlist, List<Track> tracks, {TrackSource source = TrackSource.local}) async {
    final newtracks = tracks.mapped((e) => TrackWithDate(
          dateAdded: currentTimeMS,
          track: e,
          source: source,
        ));
    playlist.tracks.addAll(newtracks);
    _updateMap(playlist);

    await _savePlaylistToStorage(playlist);
  }

  Future<void> insertTracksInPlaylist(Playlist playlist, List<TrackWithDate> tracks, int index) async {
    playlist.tracks.insertAllSafe(index, tracks);
    _updateMap(playlist);

    await _savePlaylistToStorage(playlist);
  }

  Future<void> insertTracksInPlaylistWithEachIndex(Playlist playlist, Map<TrackWithDate, int> twdAndIndexes) async {
    final entries = twdAndIndexes.entries.toList();
    // // reverse looping won't be a good choice
    // // supposing inserting at index 28 while the first loop will deal with only 25 elements
    // // the solution is to loop accendingly and increasing indexes after each insertion
    entries.sortBy((e) => e.value);
    // int heyThoseIndexesIncreased = 0;
    entries.loop((trEntry, _) {
      final tr = trEntry.key;
      final index = trEntry.value /* + heyThoseIndexesIncreased */;
      playlist.tracks.insertSafe(index, tr);
      // heyThoseIndexesIncreased++;
    });
    _updateMap(playlist);
    await _savePlaylistToStorage(playlist);
  }

  Future<void> removeTracksFromPlaylist(Playlist playlist, List<int> indexes) async {
    // sort & reverse loop to maintain correct index
    indexes.sort();
    indexes.reverseLoop((e, index) => playlist.tracks.removeAt(e));
    _updateMap(playlist);
    await _savePlaylistToStorage(playlist);
  }

  Future<void> _replaceTheseTracksInPlaylists(
    bool Function(TrackWithDate e) test,
    TrackWithDate Function(TrackWithDate old) newElement,
  ) async {
    // -- normal
    final playlistsToSave = <Playlist>{};
    playlistsMap.entries.toList().loop((entry, index) {
      final p = entry.value;
      p.tracks.replaceWhere(
        test,
        newElement,
        onMatch: () => playlistsToSave.add(p),
      );
    });
    await playlistsToSave.toList().loopFuture((p, index) async {
      _updateMap(p);
      await _savePlaylistToStorage(p);
    });

    // -- favourite
    favouritesPlaylist.value.tracks.replaceSingleWhere(
      test,
      newElement,
    );
    await _saveFavouritesToStorage();
  }

  Future<void> replaceTracksDirectory(String oldDir, String newDir, {Iterable<String>? forThesePathsOnly, bool ensureNewFileExists = false}) async {
    String getNewPath(String old) => old.replaceFirst(oldDir, newDir);

    await _replaceTheseTracksInPlaylists(
      (e) {
        final trackPath = e.track.path;
        if (ensureNewFileExists) {
          if (!File(getNewPath(trackPath)).existsSync()) return false;
        }
        final firstC = forThesePathsOnly != null ? forThesePathsOnly.contains(e.track.path) : true;
        final secondC = trackPath.startsWith(oldDir);
        return firstC && secondC;
      },
      (old) => TrackWithDate(
        dateAdded: old.dateAdded,
        track: Track(getNewPath(old.track.path)),
        source: old.source,
      ),
    );
  }

  Future<void> replaceTrackInAllPlaylists(Track oldTrack, Track newTrack) async {
    await _replaceTheseTracksInPlaylists(
      (e) => e.track == oldTrack,
      (old) => TrackWithDate(
        dateAdded: old.dateAdded,
        track: newTrack,
        source: old.source,
      ),
    );
  }

  void reorderTrack(Playlist playlist, int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) {
      newIndex -= 1;
    }
    final item = playlist.tracks.removeAt(oldIndex);
    await insertTracksInPlaylist(playlist, [item], newIndex);
  }

  /// Returns number of generated tracks.
  int generateRandomPlaylist() {
    final rt = NamidaGenerator.inst.getRandomTracks();
    if (rt.isEmpty) return 0;

    final l = playlistsMap.keys.where((name) => name.startsWith(k_PLAYLIST_NAME_AUTO_GENERATED)).length;
    addNewPlaylist('$k_PLAYLIST_NAME_AUTO_GENERATED ${l + 1}', tracks: rt);

    return rt.length;
  }

  Future<void> favouriteButtonOnPressed(Track track, {Track? updatedTrack}) async {
    final fvPlaylist = favouritesPlaylist.value;

    final trfv = fvPlaylist.tracks.firstWhereOrNull((element) => element.track == track);
    if (trfv == null) {
      fvPlaylist.tracks.add(TrackWithDate(
        dateAdded: currentTimeMS,
        track: track,
        source: TrackSource.local,
      ));
    } else {
      final index = fvPlaylist.tracks.indexOf(trfv);
      fvPlaylist.tracks.removeAt(index);
      if (updatedTrack != null) {
        fvPlaylist.tracks.insert(
            index,
            TrackWithDate(
              dateAdded: trfv.dateAdded,
              track: updatedTrack,
              source: trfv.source,
            ));
      }
    }

    await _saveFavouritesToStorage();
  }

  // File Related
  ///
  Future<void> prepareAllPlaylistsFile() async {
    final map = await _readPlaylistFilesCompute.thready(AppDirs.PLAYLISTS);
    playlistsMap
      ..clear()
      ..addAll(map);
    _sortPlaylists();
  }

  static Future<Map<String, Playlist>> _readPlaylistFilesCompute(String path) async {
    final map = <String, Playlist>{};
    for (final f in Directory(path).listSync()) {
      if (f is File) {
        try {
          final response = f.readAsJsonSync();
          final pl = Playlist.fromJson(response);
          map[pl.name] = pl;
        } catch (e) {
          continue;
        }
      }
    }
    return map;
  }

  Future<void> prepareDefaultPlaylistsFile() async {
    HistoryController.inst.prepareHistoryFile();
    final pl = await _prepareFavouritesFile.thready(AppPaths.FAVOURITES_PLAYLIST);
    if (pl != null) favouritesPlaylist.value = pl;
  }

  static Future<Playlist?> _prepareFavouritesFile(String path) async {
    try {
      final response = File(path).readAsJsonSync();
      return Playlist.fromJson(response);
    } catch (_) {}
    return null;
  }

  Future<bool> _saveFavouritesToStorage() async {
    favouritesPlaylist.refresh();
    final f = await File(AppPaths.FAVOURITES_PLAYLIST).writeAsJson(favouritesPlaylist.value.toJson());
    return f != null;
  }

  /// returns true if succeeded.
  Future<bool> _savePlaylistToStorage(Playlist playlist) async {
    final f = await File('${AppDirs.PLAYLISTS}/${playlist.name}.json').writeAsJson(playlist.toJson());
    return f != null;
  }

  Future<bool> _deletePlaylistFromStorage(Playlist playlist) async {
    return (await File('${AppDirs.PLAYLISTS}/${playlist.name}.json').deleteIfExists());
  }

  bool isOneOfDefaultPlaylists(String name) {
    return name == k_PLAYLIST_NAME_FAV || name == k_PLAYLIST_NAME_HISTORY || name == k_PLAYLIST_NAME_MOST_PLAYED;
  }

  void _updateMap(Playlist playlist, [String? name]) {
    name ??= playlist.name;
    playlistsMap[name] = playlist;
    _sortPlaylists();
  }

  void _removeFromMap(Playlist playlist) {
    playlistsMap.remove(playlist.name);
    playlistsMap.refresh();
  }

  void _sortPlaylists() => SearchSortController.inst.sortMedia(MediaType.playlist);

  final String kUnsupportedOperationMessage = 'Operation not supported for this type of playlist';
  UnsupportedError get unsupportedOperation => UnsupportedError(kUnsupportedOperationMessage);
}
