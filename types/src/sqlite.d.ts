/**
* SQLite3 module.
* This module borrows a lot of inspiration from [better-sqlite3](https://github.com/WiseLibs/better-sqlite3) and
* the [Bun sqlite module](https://bun.sh/docs/api/sqlite).
*
* @module tjs:sqlite
*/
declare module 'tjs:sqlite'{
    /** @deprecated */
    export interface IStatement {
        /**
         * Runs the SQL statement, ignoring the result. This is commonly used for
         * CREATE, INSERT and statement of that sort.
         *
         * @param args The bound parameters for the statement.
         */
        run(...args: any[]): void;

        /**
         * Runs the SQL statement, returning an array of objects with the name of the
         * columns and matching values.
         *
         * @param args The bound parameters for the statement.
         */
        all(...args: any[]): any[];

        /**
         * Free all resources associated with this statement. No other function
         * can be called on it afterwards.
         */
        finalize(): void;

        /**
         * Stringify the statement by expanding the SQL query.
         */
        toString(): string;
    }

    export interface IDatabaseOptions {
        /**
         * Whether the database needs to be created if it doesn't exist.
         * Defaults to `true`.
         */
        create: boolean;

        /**
         * Whether the database should be open in read-only mode or not.
         * Defaults to `false`.
         */
        readOnly: boolean;
    }


    export class Database {
        /**
         * Opens a SQLite database.
         *
         * @param dbName The path of the database. Defaults to `:memory:`, which
         * opens an in-memory database.
         * @param options Options when opening the database.
         */
        constructor(dbName: string, options: IDatabaseOptions);

        /**
         * Execute the given SQL statement(s).
         *
         * @param sql - The SQL statement(s) that will run.
         */
        exec(sql: string, options?: { signal?: AbortSignal }): Promise<void>;

        /**
         * Execute a query and return all rows as an array of objects.
         * Prepares internally; parameters can be passed as an array (positional) or object (named, e.g. {$txt: 'foo'}).
         */
        all(sql: string, params?: any[] | Record<string, any>, options?: { signal?: AbortSignal }): Promise<any[]>;

        /**
         * Create a prepared statement, to run SQL queries.
         *
         * @param sql - The SQL query that will run.
         */
        /** @deprecated */
        prepare(sql: string): IStatement;

        /**
         * Closes the database. No further operations can be performed afterwards.
         */
        close(): void;

        /**
         * Load an extension from file
         * @param file location of the shared library
         * @param entrypoint entrypoint, if left empty a guess is made by sqlite
         */
        loadExtension(file:string, entrypoint?:string): undefined;

    }
}
