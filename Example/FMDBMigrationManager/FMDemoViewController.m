//
//  FMDemoViewController.m
//  FMDBMigrationManager
//
//  Created by zisulu on 03/18/2020.
//  Copyright (c) 2020 zisulu. All rights reserved.
//

#import "FMDemoViewController.h"
#import <FMDBMigrationManager/FMDBMigrationManager.h>

@interface FMDemoExampleMigration : NSObject <FMDBMigrating>
@property (nonatomic) NSString *name;
@property (nonatomic, assign) uint64_t version;
@property (nonatomic, copy) NSString *SQL;
@end

@implementation FMDemoExampleMigration

- (BOOL)migrateDatabase:(FMDatabase *)database error:(out NSError *__autoreleasing *)error
{
    BOOL success = [database executeStatements:self.SQL];
    if (!success && error) *error = database.lastError;
    return success;
}

@end

@interface FMDemoViewController ()
@property (nonatomic, strong) UITextView *output;
@end

@implementation FMDemoViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.output = [[UITextView alloc] initWithFrame:self.view.bounds];
    self.output.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.output.editable = NO;
    self.output.font = [UIFont systemFontOfSize:16];
    self.output.textContainerInset = UIEdgeInsetsMake(40, 20, 20, 20);
    [self.view addSubview:self.output];
    [self runExample];
}

- (void)runExample
{
    NSMutableString *log = [NSMutableString stringWithString:@"FMDB migration example\n\n"];
    FMDatabase *database = [FMDatabase databaseWithPath:@":memory:"];
    if (![database open]) {
        self.output.text = [NSString stringWithFormat:@"Could not open database: %@", database.lastError];
        return;
    }

    FMDBMigrationManager *manager = [FMDBMigrationManager managerWithDatabase:database migrationsBundle:[NSBundle mainBundle]];
    manager.dynamicMigrationsEnabled = NO;

    NSArray *names = @[@"Create notes", @"Add category", @"Demonstrate rollback"];
    NSArray *statements = @[
        @"CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL); INSERT INTO notes (title) VALUES ('First note');",
        @"ALTER TABLE notes ADD COLUMN category TEXT; UPDATE notes SET category = 'General';",
        @"INSERT INTO notes (title, category) VALUES ('Rolled back', 'Temporary'); INSERT INTO missing_table VALUES (1);"
    ];
    for (NSUInteger index = 0; index < names.count; index++) {
        FMDemoExampleMigration *migration = [FMDemoExampleMigration new];
        migration.name = names[index];
        migration.version = index + 1;
        migration.SQL = statements[index];
        [manager addMigration:migration];
    }

    NSError *error = nil;
    if (!manager.hasMigrationsTable && ![manager createMigrationsTable:&error]) {
        self.output.text = [NSString stringWithFormat:@"Could not create migration table: %@", error];
        [database close];
        return;
    }

    [log appendFormat:@"Pending versions: %@\n", manager.pendingVersions];
    BOOL success = [manager migrateDatabaseToVersion:UINT64_MAX progress:^(NSProgress *progress) {
        id<FMDBMigrating> migration = progress.userInfo[FMDBMigrationManagerProgressMigrationUserInfoKey];
        [log appendFormat:@"Applied version %llu: %@\n", (unsigned long long)migration.version, migration.name];
    } error:&error];
    if (!success) {
        [log appendFormat:@"Migration failed: %@\n", error ?: database.lastError];
    }
    [log appendFormat:@"\nCurrent version: %llu\nApplied: %@\nPending: %@\n\nNotes:\n",
     (unsigned long long)manager.currentVersion, manager.appliedVersions, manager.pendingVersions];

    FMResultSet *results = [database executeQuery:@"SELECT title, category FROM notes ORDER BY id"];
    if (!results) {
        [log appendFormat:@"Query failed: %@\n", database.lastError];
    } else {
        while ([results next]) {
            [log appendFormat:@"%@ (%@)\n", [results stringForColumn:@"title"], [results stringForColumn:@"category"]];
        }
        [results close];
    }
    self.output.text = log;
    [database close];
}

@end
