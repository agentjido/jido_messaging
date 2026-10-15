#include "sqlite3ext.h"
SQLITE_EXTENSION_INIT1
static void total(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
  (void)argc; (void)argv;
  sqlite3_result_int64(ctx, sqlite3_memory_used());
}
static void peak(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
  (void)argc; (void)argv;
  sqlite3_result_int64(ctx, sqlite3_memory_highwater(0));
}
static void connection(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
  (void)argc;
  int current = 0, high = 0;
  int result = sqlite3_db_status(sqlite3_context_db_handle(ctx), sqlite3_value_int(argv[0]), &current, &high, 0);
  if (result == SQLITE_OK) sqlite3_result_int(ctx, current);
  else sqlite3_result_error(ctx, "SQLite memory counter unavailable", -1);
}
int sqlite3_extension_init(sqlite3 *db, char **error, const sqlite3_api_routines *api) {
  (void)error;
  SQLITE_EXTENSION_INIT2(api);
  int result = sqlite3_create_function(db, "probe_sqlite_total", 0, SQLITE_UTF8, 0, total, 0, 0);
  if (result == SQLITE_OK) result = sqlite3_create_function(db, "probe_sqlite_peak", 0, SQLITE_UTF8, 0, peak, 0, 0);
  if (result == SQLITE_OK) result = sqlite3_create_function(db, "probe_sqlite_connection", 1, SQLITE_UTF8, 0, connection, 0, 0);
  return result;
}
