# FMDBMigrationManager

This fork is intended for personal use with private CocoaPods Specs, not public distribution. The original Layer repository is no longer accessible.

## Example

Run `pod install --project-directory=Example`, open `Example/FMDBMigrationManager.xcworkspace`, and run the example scheme on an iOS simulator.

The app runs three explicitly registered code migrations against a fresh in-memory database on each launch. Versions 1 and 2 create and update a note. Version 3 inserts another note and then deliberately executes invalid SQL. The screen shows the error, applied and pending versions, and the remaining note: version 3's insert is rolled back, while versions 1 and 2 remain applied. See `Example/FMDBMigrationManager/FMDemoViewController.m` for the complete implementation.

## Usage

Create a manager with an `FMDatabase` or a database path and a non-nil bundle. Create the migrations table before migrating, and check errors from both operations:

```objc
FMDBMigrationManager *manager =
    [FMDBMigrationManager managerWithDatabaseAtPath:databasePath
                                    migrationsBundle:[NSBundle mainBundle]];
NSError *error = nil;
if (!manager.hasMigrationsTable && ![manager createMigrationsTable:&error]) {
    NSLog(@"Could not create migrations table: %@", error);
    return;
}

BOOL success = [manager migrateDatabaseToVersion:UINT64_MAX
    progress:^(NSProgress *progress) {
        id<FMDBMigrating> migration = progress.userInfo[FMDBMigrationManagerProgressMigrationUserInfoKey];
        NSLog(@"Migration ready to commit: %@", migration.name);
    } error:&error];
if (!success) {
    NSLog(@"Migration failed: %@", error ?: manager.database.lastError);
}
```

The manager discovers SQL files in the supplied bundle with names such as `1_create_notes.sql` and, by default, instantiates classes conforming to `FMDBMigrating`. Include SQL files in the app target's bundle. Alternatively, set `dynamicMigrationsEnabled = NO` before accessing migrations and register instances with `addMigration:` or `addMigrations:` as in the example. SQL files in the bundle are still discovered. Use unique versions and implement `migrateDatabase:error:` to return `NO` and populate the error on failure.

Migrations run in version order. The manager attempts to begin and commit a separate transaction for each migration, so this is not an all-or-nothing batch: earlier successful commits remain in place when a later migration fails or is cancelled. It attempts to roll back the current migration on failure or cancellation, but does not check whether transaction operations succeed; see Known Limitations below.

After a migration and its version insert succeed, the manager increments progress and invokes the callback **before** attempting to commit. A callback therefore does not confirm persistence. Cancelling in the callback attempts to roll back that migration, even though its completed count has already increased. The total counts all pending versions, including those above the requested target; reaching the target can leave progress below its total. Inspect the database and `appliedVersions` and `pendingVersions` before retrying, particularly after transaction errors.

Serialize access to the database during migration. Do not start migrations inside an existing transaction or control transactions from migration SQL, migration objects, or progress callbacks.

## Known Limitations

These observations describe the current Core implementation, not guarantees of successful recovery:

- Transaction results are ignored: `beginTransaction`, `commit`, and `rollback` are not checked. A failed begin can leave migration statements running outside the intended transaction or inside a caller's transaction; a failed commit can still yield `YES`; a failed rollback can leave changes or an open transaction. The manager also begins and commits a transaction before stopping at a pending version above the target.
- File migrations read UTF-8 SQL with `error:nil`. A missing, unreadable, or invalid UTF-8 file loses its read error, and the resulting `nil` SQL is passed to FMDB. The manager cannot reliably report the file failure or ensure that the file's statements were executed before recording the version.
- Error propagation is incomplete. A failed version insert returns `NO` without assigning its database error to the supplied `NSError **`; rollback errors are not reported. A custom migration must supply its own error when returning `NO`. Database opening in the initializer is also unchecked. `database.lastError` may help diagnose a failure but can be stale or overwritten, including by rollback; it is not a substitute for a preserved original error.
- Migration versions are exposed as `uint64_t`, but SQLite `INTEGER` is signed 64-bit and FMDB binds numbers through a signed 64-bit integer. Use unique version numbers in the range `0` through `INT64_MAX`; values above that range are not reliably represented or ordered. `UINT64_MAX` in the example is a target sentinel, not a recommended migration version. Filename parsing also does not check numeric overflow.
- Duplicate versions are not rejected during discovery or registration. Lookup returns the first matching migration, and the unique version record can cause a later insert to fail; do not register the same version twice.
- The discovered migration list is cached. Set `dynamicMigrationsEnabled` before first accessing migrations or version properties; changing it afterward does not rediscover classes or files. Explicitly added migrations are appended to the cached list. Dynamic discovery instantiates matching runtime classes with `new`, so those classes must support that initialization.
- Version queries and `hasMigrationsTable` do not expose query errors separately from their results. A missing table produces `nil` for `appliedVersions`, while `pendingVersions` reports all discovered versions. Create and verify the table before migrating; a no-pending-migrations call can otherwise return `YES` without creating it.

## Requirements

The podspec targets iOS 15.0 and macOS 12.0. The example Podfile and Xcode project target iOS 15.0.

The original `System` (default, `FMDB/standard >= 2.7.12`) and `Standalone` (`FMDB/standalone >= 2.7.12`) subspecs are available. Library sources are in `FMDBMigrationManager/Core/`; the example uses the `FMDemo` class prefix.

## Installation

For local development, the example Podfile references the checkout directly:

```ruby
pod 'FMDBMigrationManager', :path => '../'
```

Private Specs use requires a privately configured Specs source and an accessible source repository and matching tag. Configure these locally for your own environment; no private address or publication is assumed. The current podspec's source and tag must be checked before use.

## Tests

`Example/Tests/Tests.m` contains 15 XCTest methods covering ordering, target versions, ordinary rollback and cancellation, SQL file discovery, and edge cases. Some tests explicitly document known defects in the current implementation; passing those tests does not mean those behaviors are desirable.

On macOS with Xcode, CocoaPods, and an available iOS simulator, install the example dependencies, list simulator IDs, and run the suite:

```sh
pod install --project-directory=Example
xcrun simctl list devices available
xcodebuild test -workspace Example/FMDBMigrationManager.xcworkspace \
  -scheme FMDBMigrationManager-Example \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_ID>'
```

Replace `<SIMULATOR_ID>` with an available device UUID. Installing pods may update generated files. The existing Travis configuration is historical and should not be treated as current CI status.

## Author

The original library was authored by Blake Watters. This fork retains the MIT notice for zisulu, zisulwl@163.com.

## License

The repository includes MIT-licensed material and migration source files carrying Layer Inc.'s Apache License 2.0 notice. See `LICENSE` and `LICENSE-APACHE` for the applicable notices and license texts. The original CocoaPods 1.4.1 specification identifies the upstream library as Apache 2.0; the original upstream repository is no longer accessible for verification of any additional notices.
