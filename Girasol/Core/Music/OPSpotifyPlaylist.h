// SPDX-License-Identifier: CC0-1.0
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One track of a Spotify playlist, as Spotify names it.
@interface OPSpotifyTrack : NSObject
/// The base-62 id of `spotify:track:<id>`.
@property (nonatomic, copy, readonly) NSString *trackId;
@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, copy, readonly) NSArray<NSString *> *artists;
/// Only the playlist pages after the first name it (see `OPSpotifyPlaylist`).
@property (nonatomic, copy, readonly, nullable) NSString *album;
@property (nonatomic, readonly) NSTimeInterval duration;
@end

/// A shared Spotify playlist, read without an account: the embed player's
/// page (open.spotify.com/embed/playlist/<id>) carries the name, cover and
/// the first 100 tracks, and an anonymous token that Spotify's own web
/// player API (pathfinder `fetchPlaylist`) accepts for every page. Spotify's
/// public Web API refuses that token (429 QUOTA_EXCEEDED). Should the
/// pathfinder query ever be refused (its persisted-query hash is Spotify's
/// and may change), the embed's 100 tracks are what there is — `total`
/// then says how many are missing when known.
@interface OPSpotifyPlaylist : NSObject
@property (nonatomic, copy, readonly) NSString *playlistId;
@property (nonatomic, copy, readonly) NSString *name;
/// Who made it, as the embed shows it.
@property (nonatomic, copy, readonly) NSString *owner;
@property (nonatomic, copy, readonly, nullable) NSString *coverURL;
@property (nonatomic, copy, readonly) NSArray<OPSpotifyTrack *> *tracks;
/// How many tracks the playlist has, -1 when unknown.
@property (nonatomic, readonly) NSInteger total;
/// How the tracks were read, for the log ("pathfinder 150", "embed only: …").
@property (nonatomic, copy, readonly) NSString *source;

/// Calls back on the main queue, nil when the playlist could not be read
/// (private, deleted, offline).
+ (void)fetchPlaylistId:(NSString *)playlistId
             completion:(void (^)(OPSpotifyPlaylist *_Nullable playlist))completion;
@end

NS_ASSUME_NONNULL_END
