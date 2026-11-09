@import XCTest;
@import FMDBMigrationManager;
#import <FMDB/FMDatabaseAdditions.h>
#import <sqlite3.h>

@interface TestMigration : NSObject <FMDBMigrating>
@property (nonatomic, strong) NSString *name;
@property (nonatomic) uint64_t version;
@property (nonatomic, copy) BOOL (^operation)(FMDatabase *, NSError **);
@end

@implementation TestMigration
- (BOOL)migrateDatabase:(FMDatabase *)database error:(out NSError *__autoreleasing *)error
{
    if (!self.operation) {
        if (error) *error = [NSError errorWithDomain:@"TestMigration" code:1 userInfo:nil];
        return NO;
    }
    return self.operation(database, error);
}
@end

@interface TransactionCountingDatabase : FMDatabase
@property (nonatomic) NSUInteger beginCount;
@end

@implementation TransactionCountingDatabase
- (BOOL)beginTransaction
{
    self.beginCount++;
    return [super beginTransaction];
}
@end

@interface OverriddenSQLMigration : FMDBFileMigration
@end

@implementation OverriddenSQLMigration
- (NSString *)SQL
{
    return @"CREATE TABLE overridden_items (id INTEGER)";
}
@end

@interface RollbackFailingDatabase : FMDatabase
@property (nonatomic) BOOL failRollback;
@property (nonatomic, strong) NSError *simulatedRollbackError;
@end

@implementation RollbackFailingDatabase
- (BOOL)rollback
{
    if (self.failRollback) return NO;
    return [super rollback];
}

- (NSError *)lastError
{
    if (self.failRollback) return self.simulatedRollbackError;
    return [super lastError];
}
@end

@interface Tests : XCTestCase
@property (nonatomic, copy) NSString *bundlePath;
@property (nonatomic, strong) FMDBMigrationManager *manager;
@end

@implementation Tests

- (void)setUp
{
    [super setUp];
    self.bundlePath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                       [NSString stringWithFormat:@"%@.bundle", [NSUUID UUID].UUIDString]];
    NSError *error = nil;
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:self.bundlePath
                                           withIntermediateDirectories:YES attributes:nil error:&error]);
    XCTAssertNil(error);
    NSDictionary *info = @{ @"CFBundleIdentifier": [NSString stringWithFormat:@"test.%@", [NSUUID UUID].UUIDString],
                            @"CFBundleName": @"MigrationTests", @"CFBundlePackageType": @"BNDL" };
    XCTAssertTrue([info writeToFile:[self.bundlePath stringByAppendingPathComponent:@"Info.plist"] atomically:YES]);
}

- (FMDBMigrationManager *)manager
{
    if (!_manager) {
        NSBundle *bundle = [NSBundle bundleWithPath:self.bundlePath];
        XCTAssertNotNil(bundle);
        if (!bundle) return nil;
        _manager = [FMDBMigrationManager managerWithDatabase:[FMDatabase databaseWithPath:@":memory:"] migrationsBundle:bundle];
        _manager.dynamicMigrationsEnabled = NO;
    }
    return _manager;
}

- (void)tearDown
{
    [_manager.database close];
    self.manager = nil;
    NSError *error = nil;
    XCTAssertTrue([[NSFileManager defaultManager] removeItemAtPath:self.bundlePath error:&error]);
    XCTAssertNil(error);
    [super tearDown];
}

- (TestMigration *)migration:(uint64_t)version SQL:(NSString *)SQL
{
    TestMigration *migration = [TestMigration new];
    migration.version = version;
    migration.name = [NSString stringWithFormat:@"migration%llu", (unsigned long long)version];
    migration.operation = ^BOOL(FMDatabase *database, NSError **error) {
        BOOL success = [database executeStatements:SQL];
        if (!success && error) *error = database.lastError;
        return success;
    };
    return migration;
}

- (void)createMigrationsTable
{
    NSError *error = nil;
    XCTAssertTrue([self.manager createMigrationsTable:&error]);
    XCTAssertNil(error);
}

- (void)testManualMigrationsAreSortedAndCanBeAddedAfterDiscovery
{
    TestMigration *third = [self migration:3 SQL:@"CREATE TABLE third (id INTEGER)"];
    TestMigration *first = [self migration:1 SQL:@"CREATE TABLE first (id INTEGER)"];
    TestMigration *second = [self migration:2 SQL:@"CREATE TABLE second (id INTEGER)"];
    [self.manager addMigration:third];
    XCTAssertEqualObjects([self.manager.migrations valueForKey:@"version"], (@[@3]));
    [self.manager addMigrations:@[second, first]];
    XCTAssertEqualObjects([self.manager.migrations valueForKey:@"version"], (@[@1, @2, @3]));
    XCTAssertEqualObjects(self.manager.pendingVersions, (@[@1, @2, @3]));
    XCTAssertEqual([self.manager migrationForVersion:2], second);
    XCTAssertEqual([self.manager migrationForName:@"migration1"], first);
    XCTAssertNil([self.manager migrationForVersion:4]);
    XCTAssertNil([self.manager migrationForName:@"missing"]);
    XCTAssertFalse(self.manager.hasMigrationsTable);
    XCTAssertNil(self.manager.appliedVersions);
    XCTAssertEqual(self.manager.currentVersion, (uint64_t)0);
    XCTAssertEqual(self.manager.originVersion, (uint64_t)0);
    XCTAssertTrue(self.manager.needsMigration);
}

- (void)testTargetVersionAndSuccessfulMigration
{
    [self.manager addMigrations:@[[self migration:3 SQL:@"INSERT INTO items VALUES (3)"],
                                  [self migration:1 SQL:@"CREATE TABLE items (id INTEGER); INSERT INTO items VALUES (1)"],
                                  [self migration:2 SQL:@"INSERT INTO items VALUES (2)"]]];
    [self createMigrationsTable];
    NSMutableArray *reported = [NSMutableArray array];
    NSError *error = nil;
    BOOL success = [self.manager migrateDatabaseToVersion:2 progress:^(NSProgress *progress) {
        NSNumber *version = progress.userInfo[FMDBMigrationManagerProgressVersionUserInfoKey];
        id<FMDBMigrating> migration = progress.userInfo[FMDBMigrationManagerProgressMigrationUserInfoKey];
        XCTAssertEqual(migration.version, version.unsignedLongLongValue);
        XCTAssertEqual(progress.totalUnitCount, (int64_t)3);
        XCTAssertEqual(progress.completedUnitCount, (int64_t)(reported.count + 1));
        [reported addObject:version];
    } error:&error];
    XCTAssertTrue(success);
    XCTAssertNil(error);
    XCTAssertEqualObjects(reported, (@[@1, @2]));
    XCTAssertEqualObjects(self.manager.appliedVersions, (@[@1, @2]));
    XCTAssertEqualObjects(self.manager.pendingVersions, (@[@3]));
    XCTAssertEqual(self.manager.originVersion, (uint64_t)1);
    XCTAssertEqual(self.manager.currentVersion, (uint64_t)2);
    XCTAssertTrue(self.manager.needsMigration);
    XCTAssertEqual([self.manager.database intForQuery:@"SELECT COUNT(*) FROM items"], 2);
    XCTAssertTrue([self.manager migrateDatabaseToVersion:UINT64_MAX progress:nil error:&error]);
    XCTAssertNil(error);
    XCTAssertEqualObjects(self.manager.appliedVersions, (@[@1, @2, @3]));
    XCTAssertEqualObjects(self.manager.pendingVersions, (@[]));
    XCTAssertFalse(self.manager.needsMigration);
    XCTAssertEqual([self.manager.database intForQuery:@"SELECT COUNT(*) FROM items"], 3);
}

- (void)testFailureRollsBackCurrentMigrationButKeepsPreviousCommit
{
    [self.manager addMigrations:@[[self migration:1 SQL:@"CREATE TABLE items (id INTEGER); INSERT INTO items VALUES (1)"],
                                  [self migration:2 SQL:@"INSERT INTO items VALUES (2); INSERT INTO missing VALUES (2)"],
                                  [self migration:3 SQL:@"INSERT INTO items VALUES (3)"]]];
    [self createMigrationsTable];
    NSError *error = nil;
    XCTAssertFalse([self.manager migrateDatabaseToVersion:UINT64_MAX progress:nil error:&error]);
    XCTAssertNotNil(error);
    XCTAssertEqualObjects(self.manager.appliedVersions, (@[@1]));
    XCTAssertEqualObjects(self.manager.pendingVersions, (@[@2, @3]));
    XCTAssertEqual(self.manager.currentVersion, (uint64_t)1);
    XCTAssertEqual([self.manager.database intForQuery:@"SELECT COUNT(*) FROM items"], 1);
    XCTAssertEqual([self.manager.database intForQuery:@"SELECT id FROM items"], 1);
}

- (void)testCancellationRollsBackCurrentMigrationButKeepsPreviousCommit
{
    [self.manager addMigrations:@[[self migration:1 SQL:@"CREATE TABLE items (id INTEGER); INSERT INTO items VALUES (1)"],
                                  [self migration:2 SQL:@"INSERT INTO items VALUES (2)"],
                                  [self migration:3 SQL:@"INSERT INTO items VALUES (3)"]]];
    [self createMigrationsTable];
    NSMutableArray *reported = [NSMutableArray array];
    NSError *error = nil;
    BOOL success = [self.manager migrateDatabaseToVersion:UINT64_MAX progress:^(NSProgress *progress) {
        NSNumber *version = progress.userInfo[FMDBMigrationManagerProgressVersionUserInfoKey];
        [reported addObject:version];
        if (version.unsignedLongLongValue == 2) [progress cancel];
    } error:&error];
    XCTAssertFalse(success);
    XCTAssertEqualObjects(error.domain, FMDBMigrationManagerErrorDomain);
    XCTAssertEqual(error.code, FMDBMigrationManagerErrorMigrationCancelled);
    XCTAssertEqualObjects(reported, (@[@1, @2]));
    XCTAssertEqualObjects(self.manager.appliedVersions, (@[@1]));
    XCTAssertEqualObjects(self.manager.pendingVersions, (@[@2, @3]));
    XCTAssertEqual([self.manager.database intForQuery:@"SELECT COUNT(*) FROM items"], 1);
    error = nil;
    XCTAssertTrue([self.manager migrateDatabaseToVersion:UINT64_MAX progress:nil error:&error]);
    XCTAssertNil(error);
    XCTAssertEqualObjects(self.manager.appliedVersions, (@[@1, @2, @3]));
    XCTAssertEqual([self.manager.database intForQuery:@"SELECT COUNT(*) FROM items"], 3);
}

- (void)testMissingMigrationsTableRollsBackMigration
{
    [self.manager addMigration:[self migration:1 SQL:@"CREATE TABLE should_rollback (id INTEGER)"]];
    XCTAssertFalse([self.manager migrateDatabaseToVersion:UINT64_MAX progress:nil error:nil]);
    XCTAssertFalse([self.manager.database tableExists:@"should_rollback"]);
    XCTAssertFalse(self.manager.hasMigrationsTable);
    XCTAssertEqualObjects(self.manager.pendingVersions, (@[@1]));
}

- (void)testFileDiscoveryAndExecution
{
    NSDictionary *files = @{ @"10_second.sql": @"INSERT INTO file_items VALUES (10)",
                             @"2_first.sql": @"CREATE TABLE file_items (id INTEGER); INSERT INTO file_items VALUES (2)",
                             @"not_a_migration.sql": @"INVALID SQL", @"3_.sql": @"INVALID SQL",
                             @"4_ignored.txt": @"INVALID SQL" };
    [files enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *SQL, BOOL *stop) {
        NSError *error = nil;
        XCTAssertTrue([SQL writeToFile:[self.bundlePath stringByAppendingPathComponent:name]
                            atomically:YES encoding:NSUTF8StringEncoding error:&error]);
        XCTAssertNil(error);
    }];
    XCTAssertTrue(FMDBIsMigrationAtPath(@"2_first.sql"));
    XCTAssertFalse(FMDBIsMigrationAtPath(@"3_.sql"));
    XCTAssertEqualObjects([self.manager.migrations valueForKey:@"version"], (@[@2, @10]));
    FMDBFileMigration *first = (FMDBFileMigration *)[self.manager migrationForName:@"first"];
    XCTAssertTrue([first isKindOfClass:[FMDBFileMigration class]]);
    XCTAssertEqualObjects(first.SQL, files[@"2_first.sql"]);
    [self createMigrationsTable];
    NSError *error = nil;
    XCTAssertTrue([self.manager migrateDatabaseToVersion:UINT64_MAX progress:nil error:&error]);
    XCTAssertNil(error);
    XCTAssertEqualObjects(self.manager.appliedVersions, (@[@2, @10]));
    XCTAssertEqual([self.manager.database intForQuery:@"SELECT COUNT(*) FROM file_items"], 2);
}

- (void)testExistingTransactionIsCommittedBySuccessfulMigration
{
    [self createMigrationsTable];
    FMDatabase *database = self.manager.database;
    XCTAssertTrue([database executeUpdate:@"CREATE TABLE caller_items (id INTEGER)"]);
    [self.manager addMigration:[self migration:1 SQL:@"CREATE TABLE migrated_items (id INTEGER)"]];
    XCTAssertTrue([database beginTransaction]);
    XCTAssertTrue([database executeUpdate:@"INSERT INTO caller_items VALUES (1)"]);

    NSError *error = nil;
    XCTAssertTrue([self.manager migrateDatabaseToVersion:UINT64_MAX progress:nil error:&error]);
    XCTAssertNil(error);
    XCTAssertFalse(database.isInTransaction);
    XCTAssertEqual([database intForQuery:@"SELECT COUNT(*) FROM caller_items"], 1);
    XCTAssertTrue([database tableExists:@"migrated_items"]);
    XCTAssertEqualObjects(self.manager.appliedVersions, (@[@1]));
}

- (void)testExistingTransactionIsRolledBackByFailedMigration
{
    [self createMigrationsTable];
    FMDatabase *database = self.manager.database;
    XCTAssertTrue([database executeUpdate:@"CREATE TABLE caller_items (id INTEGER)"]);
    [self.manager addMigration:[self migration:1 SQL:@"INSERT INTO missing_table VALUES (1)"]];
    XCTAssertTrue([database beginTransaction]);
    XCTAssertTrue([database executeUpdate:@"INSERT INTO caller_items VALUES (1)"]);

    NSError *error = nil;
    XCTAssertFalse([self.manager migrateDatabaseToVersion:UINT64_MAX progress:nil error:&error]);
    XCTAssertNotNil(error);
    XCTAssertFalse(database.isInTransaction);
    XCTAssertEqual([database intForQuery:@"SELECT COUNT(*) FROM caller_items"], 0);
    XCTAssertEqualObjects(self.manager.appliedVersions, (@[]));
}

- (void)testDeferredForeignKeyCommitFailureIsNotReported
{
    [self createMigrationsTable];
    FMDatabase *database = self.manager.database;
    XCTAssertTrue([database executeStatements:@"PRAGMA foreign_keys = ON; CREATE TABLE parent (id INTEGER PRIMARY KEY); CREATE TABLE child (parent_id INTEGER REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED)"]);
    XCTAssertEqual([database intForQuery:@"PRAGMA foreign_keys"], 1);
    [self.manager addMigration:[self migration:1 SQL:@"INSERT INTO child VALUES (42)"]];

    NSError *error = nil;
    XCTAssertTrue([self.manager migrateDatabaseToVersion:UINT64_MAX progress:nil error:&error]);
    XCTAssertNil(error);
    XCTAssertTrue(database.isInTransaction);
    XCTAssertEqual([database intForQuery:@"SELECT COUNT(*) FROM child"], 1);
    XCTAssertEqualObjects(self.manager.appliedVersions, (@[@1]));
    XCTAssertTrue([database rollback]);
    XCTAssertEqual([database intForQuery:@"SELECT COUNT(*) FROM child"], 0);
    XCTAssertEqualObjects(self.manager.appliedVersions, (@[]));
    XCTAssertEqualObjects(self.manager.pendingVersions, (@[@1]));
}

- (void)testMissingMigrationsTableDoesNotReturnWriteError
{
    [self.manager addMigration:[self migration:1 SQL:@"CREATE TABLE should_rollback_with_error (id INTEGER)"]];
    NSError *error = nil;
    XCTAssertFalse([self.manager migrateDatabaseToVersion:UINT64_MAX progress:nil error:&error]);
    XCTAssertNil(error);
    XCTAssertFalse([self.manager.database tableExists:@"should_rollback_with_error"]);
    XCTAssertFalse(self.manager.database.isInTransaction);
}

- (void)testMissingSQLFileIsRecordedAsSuccessfulMigration
{
    NSString *path = [self.bundlePath stringByAppendingPathComponent:@"1_missing.sql"];
    FMDBFileMigration *migration = [FMDBFileMigration migrationWithPath:path];
    XCTAssertNotNil(migration);
    XCTAssertNil(migration.SQL);
    [self.manager addMigration:migration];
    [self createMigrationsTable];

    NSError *error = nil;
    XCTAssertTrue([self.manager migrateDatabaseToVersion:UINT64_MAX progress:nil error:&error]);
    XCTAssertNil(error);
    XCTAssertEqualObjects(self.manager.appliedVersions, (@[@1]));
    XCTAssertEqualObjects(self.manager.pendingVersions, (@[]));
    XCTAssertFalse(self.manager.database.isInTransaction);
}

- (void)testTargetBeforePendingVersionBeginsTransaction
{
    TransactionCountingDatabase *database = [TransactionCountingDatabase databaseWithPath:@":memory:"];
    self.manager = [FMDBMigrationManager managerWithDatabase:database migrationsBundle:[NSBundle bundleWithPath:self.bundlePath]];
    self.manager.dynamicMigrationsEnabled = NO;
    [self createMigrationsTable];
    [self.manager addMigration:[self migration:2 SQL:@"CREATE TABLE should_not_exist (id INTEGER)"]];

    NSError *error = nil;
    XCTAssertTrue([self.manager migrateDatabaseToVersion:1 progress:nil error:&error]);
    XCTAssertNil(error);
    XCTAssertEqual(database.beginCount, (NSUInteger)1);
    XCTAssertFalse(database.isInTransaction);
    XCTAssertFalse([database tableExists:@"should_not_exist"]);
    XCTAssertEqualObjects(self.manager.pendingVersions, (@[@2]));
}

- (void)testFileMigrationDispatchesOverriddenSQL
{
    NSString *path = [self.bundlePath stringByAppendingPathComponent:@"1_override.sql"];
    NSError *error = nil;
    OverriddenSQLMigration *migration = [OverriddenSQLMigration migrationWithPath:path];
    XCTAssertNotNil(migration);
    [self.manager addMigration:migration];
    [self createMigrationsTable];

    error = nil;
    XCTAssertTrue([self.manager migrateDatabaseToVersion:UINT64_MAX progress:nil error:&error]);
    XCTAssertNil(error);
    XCTAssertTrue([self.manager.database tableExists:@"overridden_items"]);
    XCTAssertFalse([self.manager.database tableExists:@"file_items"]);
    XCTAssertEqualObjects(self.manager.appliedVersions, (@[@1]));
}

- (void)testSQLiteAutomaticRollbackDoesNotReportRollbackFailure
{
    [self createMigrationsTable];
    FMDatabase *database = self.manager.database;
    XCTAssertTrue([database executeStatements:@"CREATE TABLE unique_items (id INTEGER UNIQUE); INSERT INTO unique_items VALUES (1)"]);
    [self.manager addMigration:[self migration:1 SQL:@"INSERT INTO unique_items VALUES (2); INSERT OR ROLLBACK INTO unique_items VALUES (1)"]];

    NSError *error = nil;
    XCTAssertFalse([self.manager migrateDatabaseToVersion:UINT64_MAX progress:nil error:&error]);
    XCTAssertNotNil(error);
    XCTAssertEqual(error.code, SQLITE_CONSTRAINT);
    XCTAssertNil(error.userInfo[@"FMDBMigrationManagerRollbackError"]);
    XCTAssertNotEqual(sqlite3_get_autocommit(database.sqliteHandle), 0);
    XCTAssertEqual([database intForQuery:@"SELECT COUNT(*) FROM unique_items"], 1);
    XCTAssertEqualObjects(self.manager.appliedVersions, (@[]));
    XCTAssertEqualObjects(self.manager.pendingVersions, (@[@1]));
}

- (void)testRollbackFailureIsNotIncludedInMigrationError
{
    RollbackFailingDatabase *database = [RollbackFailingDatabase databaseWithPath:@":memory:"];
    self.manager = [FMDBMigrationManager managerWithDatabase:database migrationsBundle:[NSBundle bundleWithPath:self.bundlePath]];
    self.manager.dynamicMigrationsEnabled = NO;
    [self createMigrationsTable];
    NSError *primaryError = [NSError errorWithDomain:@"MigrationFailure" code:42 userInfo:@{NSLocalizedDescriptionKey: @"primary failure"}];
    NSError *rollbackError = [NSError errorWithDomain:@"RollbackFailure" code:43 userInfo:@{NSLocalizedDescriptionKey: @"rollback failure"}];
    database.simulatedRollbackError = rollbackError;
    TestMigration *migration = [TestMigration new];
    migration.version = 1;
    migration.name = @"failure";
    migration.operation = ^BOOL(FMDatabase *db, NSError **error) {
        if (error) *error = primaryError;
        return NO;
    };
    [self.manager addMigration:migration];
    database.failRollback = YES;

    NSError *error = nil;
    XCTAssertFalse([self.manager migrateDatabaseToVersion:UINT64_MAX progress:nil error:&error]);
    XCTAssertEqualObjects(error.domain, primaryError.domain);
    XCTAssertEqual(error.code, primaryError.code);
    XCTAssertEqualObjects(error.localizedDescription, primaryError.localizedDescription);
    XCTAssertNil(error.userInfo[@"FMDBMigrationManagerRollbackError"]);
    XCTAssertTrue(database.isInTransaction);
    database.failRollback = NO;
    XCTAssertTrue([database rollback]);
    XCTAssertEqualObjects(self.manager.appliedVersions, (@[]));
    XCTAssertEqualObjects(self.manager.pendingVersions, (@[@1]));
}

@end
