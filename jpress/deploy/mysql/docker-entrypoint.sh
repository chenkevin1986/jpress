#!/bin/bash
set -eo pipefail

# if command starts with an option, prepend mysqld
if [ "${1:0:1}" = '-' ]; then
	set -- mysqld "$@"
fi

if [ "$1" = 'mysqld' ]; then
	# Get config
	DATADIR="$("$@" --verbose --help --log-bin-index=`mktemp -u` 2>/dev/null | awk '$1 == "datadir" { print $2; exit }')"

	if [ ! -d "$DATADIR/mysql" ]; then
		if [ -z "$MYSQL_ROOT_PASSWORD" -a -z "$MYSQL_ALLOW_EMPTY_PASSWORD" -a -z "$MYSQL_RANDOM_ROOT_PASSWORD" -a -z "$MYSQL_USER" -a -z "$MYSQL_PASSWORD" ]; then
			echo >&2 'error: database is uninitialized and password option is not specified '
			echo >&2 '  You need to specify one of MYSQL_ROOT_PASSWORD, MYSQL_ALLOW_EMPTY_PASSWORD, MYSQL_RANDOM_ROOT_PASSWORD, MYSQL_USER and MYSQL_PASSWORD'
			exit 1
		fi

		if [ -z "$MYSQL_ROOT_PASSWORD" -a -z "$MYSQL_ALLOW_EMPTY_PASSWORD" -a -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
			MYSQL_RANDOM_ROOT_PASSWORD='yes'
		fi

		mkdir -p "$DATADIR"
		chown -R mysql:mysql "$DATADIR"

		echo 'Initializing database'
		mysql_install_db --user=mysql --datadir="$DATADIR" --rpm --basedir=/usr/local/mysql
		echo 'Database initialized'

		"$@" --skip-networking --basedir=/usr/local/mysql &
		pid="$!"

		mysql=( mysql --protocol=socket -uroot )

		for i in {30..0}; do
			if echo 'SELECT 1' | "${mysql[@]}" &> /dev/null; then
				break
			fi
			echo 'MySQL init process in progress...'
			sleep 1
		done
		if [ "$i" = 0 ]; then
			echo >&2 'MySQL init process failed.'
			exit 1
		fi

		if [ -z "$MYSQL_INITDB_SKIP_TZINFO" ]; then
			# sed is for https://bugs.mysql.com/bug.php?id=20545
			mysql_tzinfo_to_sql /usr/share/zoneinfo | sed 's/Local time zone must be set--see zic manual page/FCTY/' | "${mysql[@]}" mysql
		fi

		if [ ! -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
			MYSQL_ROOT_PASSWORD="$(pwgen -1 32)"
			echo "GENERATED ROOT PASSWORD: $MYSQL_ROOT_PASSWORD"
		fi

		echo "What's done in this file shouldn't be replicated or products like mysql-fabric won't work."

		"${mysql[@]}" <<-EOSQL
			SET @@SESSION.SQL_LOG_BIN=0;
			DELETE FROM mysql.user ;
			CREATE USER 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
			GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION ;
			DROP DATABASE IF EXISTS test ;
			FLUSH PRIVILEGES ;
		EOSQL

		if [ ! -z "$MYSQL_ROOT_PASSWORD" ]; then
			mysql+=( -p"${MYSQL_ROOT_PASSWORD}" )
		fi

		if [ "$MYSQL_DATABASE" ]; then
			echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;" | "${mysql[@]}"
			mysql+=( "$MYSQL_DATABASE" )
		fi

		if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
			"${mysql[@]}" <<-EOSQL
				SET @@SESSION.SQL_LOG_BIN=0;
				CREATE USER '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}' ;
				GRANT Alter, Alter Routine, Create, Create Routine, Create Temporary Tables, Create View, Delete, Drop, Event, Execute, Index, Insert, Process, Replication Client, Replication Slave, Select, Show Databases, Show View, Trigger, Update ON *.* TO '${MYSQL_USER}'@'%' WITH GRANT OPTION ;
				-- REVOKE ALL ON mysql.* FROM '${MYSQL_USER}'@'%';
				delete from mysql.db where Host='%' and User='${MYSQL_USER}';
				insert into mysql.db ( Create_tmp_table_priv, Insert_priv, Host, Update_priv, Show_view_priv, Trigger_priv, Grant_priv, Index_priv, Alter_priv, User, References_priv, Create_routine_priv, Event_priv, Execute_priv, Alter_routine_priv, Drop_priv, Db, Select_priv, Delete_priv, Lock_tables_priv, Create_view_priv, Create_priv) values ( 'N', 'N', '%', 'N', 'N', 'N', 'N', 'N', 'N', '${MYSQL_USER}', 'N', 'N', 'N', 'N', 'N', 'N', 'performance_schema', 'N', 'N', 'N', 'N', 'N');
				insert into mysql.db ( Create_tmp_table_priv, Insert_priv, Host, Update_priv, Show_view_priv, Trigger_priv, Grant_priv, Index_priv, Alter_priv, User, References_priv, Create_routine_priv, Event_priv, Execute_priv, Alter_routine_priv, Drop_priv, Db, Select_priv, Delete_priv, Lock_tables_priv, Create_view_priv, Create_priv) values ( 'N', 'N', '%', 'N', 'N', 'N', 'N', 'N', 'N', '${MYSQL_USER}', 'N', 'N', 'N', 'N', 'N', 'N', 'mysql', 'N', 'N', 'N', 'N', 'N');
				FLUSH PRIVILEGES ;
			EOSQL

		    echo "CREATE mysql USER '$MYSQL_USER($MYSQL_PASSWORD)' successful."

			if [ "$MYSQL_DATABASE" ]; then
				echo "GRANT ALL ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'%' ;" | "${mysql[@]}"

			 	echo "CREATE database '$MYSQL_DATABASE' successful"
			fi
			echo 'FLUSH PRIVILEGES ;' | "${mysql[@]}"

		fi

		echo
		for f in /docker-entrypoint-initdb.d/*; do
			case "$f" in
				*.sh)     echo "$0: running $f"; . "$f" ;;
				*.sql)    echo "$0: running $f"; "${mysql[@]}" < "$f"; echo ;;
				*.sql.gz) echo "$0: running $f"; gunzip -c "$f" | "${mysql[@]}"; echo ;;
				*)        echo "$0: ignoring $f" ;;
			esac
			echo
		done

		if [ ! -z "$MYSQL_ONETIME_PASSWORD" ]; then
			echo >&2
			echo >&2 'Sorry, this version of MySQL does not support "PASSWORD EXPIRE" (required for MYSQL_ONETIME_PASSWORD).'
			echo >&2
		fi
		if ! kill -s TERM "$pid" || ! wait "$pid"; then
			echo >&2 'MySQL init process failed.'
			exit 1
		fi

		echo
		echo 'MySQL init process done. Ready for start up.'
		echo
	fi

	chown -R mysql:mysql "$DATADIR"
fi

exec "$@"