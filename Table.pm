###############################################################################
##
##  DBIx::Table class
##
##  This is a base class for abstractions of DBI database tables.  It is not
##  used directly - rather, an OO representation of a table should be a
##  subclass.  The subclass must have a method called describe(), which
##  essentially configures the behavior of the methods in this class.  See
##  the documentation for details on the describe() method.
##
##  Copyright (c) 1999 J. David Lowe.  All rights reserved.  This program is
##  software; you can redistribute it and/or modify it under the same terms as
##  Perl itself.
##
###############################################################################
package DBIx::Table;

use strict;
use vars qw($VERSION);
use integer;

$VERSION = '0.02';

## Require version 5.005, because of pseudo-hashes
require 5.005;

###############################################################################
## load
##   Purpose:
##     Constructor method
##   Usage:
##     $ref = load SUBCLASS db      => $db_reference,
##                          columns => [ 'column_1', 'column_2' ],
##                          where   => { 'column'  => 'value' },
##                          orderby => ['+'|'-'] . 'column',
##                          groupby => 'column',
##                          index   => number,
##                          count   => number;
##   Return Values:
##     On successful loading of data, returns a blessed pseudohash.
##     On failure, returns undef.
###############################################################################
sub load {
    my($class) = shift;

    ## We don't want this called as an instance method.
    if (ref($class)) {
        return(undef);
    }

    ## Grab the argument hash.
    my(%args)  = @_;
    my($self) = [ { 'in_database' => 1,
                    'columns'     => 2,
                    'table'       => 3,
                    'unique_keys' => 4,
                    'related'     => 5,
                    'values'      => 6,
                    'db'          => 7,
                    'query_rows'  => 8,
                    'num_rows'    => 9,
                    'changed'     => 10,
                    'debug_level' => 11 } ];
    $self->{'in_database'} = [ ];
    $self->{'debug_level'} = 2;

    ## Need to bless early, because we have to call $self->describe...
    bless($self, $class);

    ## This method should be defined in the subclass (i.e. this class is not
    ## intended to be used directly!)
    $self->describe() || return(undef);

    ## The variables we'll be using in this function
    my($column, $first);
    my(@columns);
    my($groupby) = '';

    ## We expect a reference to a database object in the arguments.
    if ((! defined($args{'db'})) || (! ref($args{'db'}))) {
        $self->_debug(2, 'No database parameter passed to constructor!');
        return(undef);
    }
    $self->{'db'} = $args{'db'};

    ## Is there a 'where' parameter?  If so, verify that it appears legal.
    if (defined($args{'where'})) {
        ## Verify the existence of each column we'll be using in a
        ## where clause.
        if (! $self->_check_columns(\@{[keys(%{$args{'where'}})]})) {
            $self->_debug(2, "Unknown column specified in where clause.");
            return undef;
        }
    }

    ## Is there an 'orderby' parameter?
    if (defined($args{'orderby'})) {
        $args{'orderby'} =~ /^([+-])?(.*)$/;
        if (! $self->_check_columns([$2])) {
            $self->_debug(2, "Unknown column specified in orderby parameter.");
            return undef;
        }
    }
    
    ## Is there a 'columns' parameter?
    if (defined($args{'columns'})) {
        my($star_found) = 0;
        ## We have to make sure that every column passed in is allowed
        ## according to how this table has been described.
        if (! $self->_check_columns(\@{$args{'columns'}})) {
            $self->_debug(2, "Unknown column specified in columns list.");
            return undef;
        }
        foreach $column (@{$args{'columns'}}) {
            if ($column eq '*') {
                $star_found = 1;
                next;
            }
        }
        @columns = grep(!/^\*$/, @{$args{'columns'}});
        ## An asterisk in the columns means "load all columns which are local
        ## to this table."
        if ($star_found) {
            foreach $column (keys(%{$self->{'columns'}})) {
                if ((! $self->_cprop($column, 'foreign')) &&
                      (! $self->_cprop($column, 'special'))) {
                    if (! scalar(grep(/^$column$/, @columns))) {
                        push(@columns, $column);
                    }
                }
            }
        }
    }

    ## Figure out the groupby clause
    foreach $column (@columns) {
        if ($self->_cprop($column, 'special')) {
            $groupby = $self->_cprop($column, 'special')->{'groupby'} || '';
        }
    }
    if (defined($args{'groupby'})) {
        if ($groupby eq '') {
            $groupby = $args{'groupby'};
        } elsif ($groupby ne $args{'groupby'}) {
            ## This means we have conflicting GROUP BY requests, bad...
            $self->_debug(2, "Only one GROUP BY column is legal");
            return(undef);
        }
    }

    ## Let's build some SQL!
    my($sql) = "SELECT ";

    ## Start by naming all the columns we're fetching
    $sql .= $self->_columns(\@columns);

    ## Next we name the tables we're selecting from
    $sql .= $self->_from(\@columns);

    ## The WHERE clause is created by _where()
    $sql .= $self->_where($args{'where'}, \@columns);

    ## Grouping, if it's going to happen, happens here...
    if ($groupby ne '') {
        $sql .= " GROUP BY $groupby";
    }

    ## Last but not least, tell the database how to sort the output...
    if (defined($args{'orderby'})) {
        my($orderby) = $args{'orderby'};
        my($direction) = '';
        if ($orderby =~ /^\+/) {
            $direction = ' ASC';
            $orderby =~ s/^\+//;
        } elsif ($orderby =~ /^\-/) {
            $direction = ' DESC';
            $orderby =~ s/^\-//;
        }
        $sql .= " ORDER BY ";
        if ($self->_cprop($orderby, 'foreign')) {
            $sql .= $self->_cprop($orderby, 'foreign')->{'table'};
            $sql .= "." . $orderby;
        } else {
            $sql .= $self->{'table'} . "." . $orderby;
        }
        $sql .= $direction;
    }

    ## That's some fancy SQL you've got there!
    $self->_debug(1, "$sql");

    ## Perform the database query
    my($st);
    if (! ($st = $self->{'db'}->prepare($sql))) {
        $self->_debug(2, "Error preparing SQL: $sql");
        return(undef);
    }
    if (! $st->execute()) {
        $st->finish();
        $self->_debug(2, "Error executing SQL: $sql");
        return(undef);
    }


    ## Pull the data out of the database, since we've successfully queried...
    my($index) = $args{'index'} || 0;
    my($count) = $args{'count'} || 0;
    my($row);
    my($counter) = -1;
    my($rownum) = -1;
    while ($row = $st->fetchrow_hashref()) {
        $rownum++;
        ## If index and count values are provided, we might not load all of
        ## the data (all will be fetchrow()d, though...)
        if ($rownum < $index) {
            next;
        }
        if (($count) && ($rownum >= ($index + $count))) {
            next;
        }
        $counter++;

        ## Remember the fact that this row is in the database already
        $self->{'in_database'}->[$counter] = 1;

        ## Store the where data
        foreach $column (keys(%{$args{'where'}})) {
            $self->{'values'}->[$counter]->{$column} = $args{'where'}->{$column};
        }

        ## Store the returned data
        if (defined(@columns) && ($#columns >= 0)) {
            foreach $column (@columns) {
                $self->{'values'}->[$counter]->{$column} = $row->{$column};
            }
        } else {
            foreach $column (keys(%{$self->{'columns'}})) {
                $self->{'values'}->[$counter]->{$column} = $row->{$column};
            }
        }
    }
    $st->finish();
    $self->{'query_rows'} = $rownum;
    $self->{'num_rows'}   = $counter;

    ## If this object doesn't actually contain any data, we should return
    ## undef rather than an empty object.
    if ($counter == -1) {
        $self->_debug(2, "No data was stored - returning undef!");
        return(undef);
    }

    ## One object, cooked to perfection...
    return($self);
}
### end load ##################################################################



###############################################################################
## create
##   Purpose:
##     Create a new instance of the object *AND* a new entry in the appropriate
##     database table.
##   Usage:
##     $ref = create SUBCLASS db => $db_reference;
##   Return Values:
##     Returns a blessed pseudohash, or undef if there's a problem.
###############################################################################
sub create {
    my($class) = shift;
    ## We don't want this called as a method.
    if (ref($class)) {
        return(undef);
    }

    ## Grab the argument hash.
    my(%args) = @_;
    my($self) = [ { 'in_database' => 1,
                    'columns'     => 2,
                    'table'       => 3,
                    'unique_keys' => 4,
                    'related'     => 5,
                    'values'      => 6,
                    'db'          => 7,
                    'query_rows'  => 8,
                    'num_rows'    => 9,
                    'changed'     => 10,
                    'debug_level' => 11 } ];
    $self->{'in_database'} = [ 0 ];
    $self->{'debug_level'} = 2;
    bless($self, $class);

    ## This method should be defined in the subclass (i.e. this class is not
    ## intended to be used directly!)
    $self->describe() || return(undef);

    ## We expect a reference to a database object in the arguments.
    if ((! defined($args{'db'})) || (! ref($args{'db'}))) {
        $self->_debug(2, 'No database parameter passed to constructor!');
        return(undef);
    }
    $self->{'db'} = $args{'db'};

    return($self);
}
### end create ################################################################



###############################################################################
## refresh
##   Purpose:
##     Load new information into an existing object.
##   Usage:
##     $ref->refresh( 'columns' => [ 'column_1', 'column_2' ],
##                    'row'     => row_number );
##   Return Values:
##     Returns a true value on successful loading of new data, and undef on
##     failure.
###############################################################################
sub refresh {
    my($self) = shift;
    if (! ref($self)) {
        return(undef);
    }
    my(%args)      = @_;
    $args{'row'} ||= 0;

    if ((! defined($args{'columns'})) || (! ref($args{'columns'}))) {
        $self->_debug(2, 'No columns parameter passed to refresh()');
        return(undef);
    }

    if (! $self->_check_columns(\@{$args{'columns'}})) {
        $self->_debug(2, 'Unknown column specified in columns list.');
        return(undef);
    }

    my($sql) = "SELECT ";
    $sql    .= $self->_columns(\@{$args{'columns'}});
    $sql    .= $self->_from(\@{$args{'columns'}});
    $sql    .= $self->_unique_where($args{'row'}, \@{$args{'columns'}});

    ## That's some fancy SQL you've got there!
    $self->_debug(1, "$sql");

    ## Perform the database query
    my($st);
    if (! ($st = $self->{'db'}->prepare($sql))) {
        $self->_debug(2, "Error preparing SQL: $sql");
        return(undef);
    }
    if (! $st->execute()) {
        $st->finish();
        $self->_debug(2, "Error executing SQL: $sql");
        return(undef);
    }

    my($row) = $st->fetchrow_hashref();
    if ($row) {
        my($column);
        if (defined(@{$args{'columns'}}) && (scalar(@{$args{'columns'}}) > 0)) {
            foreach $column (@{$args{'columns'}}) {
                $self->{'values'}->[$args{'row'}]->{$column}  = $row->{$column};
                $self->{'changed'}->[$args{'row'}]->{$column} = 0;
            }
        }
    } else {
        $self->_debug(2, "No data returned by SQL in refresh()...");
        return(undef);
    }
    $st->finish();

    return 1;
}
### end refresh ###############################################################



###############################################################################
## commit
##   Purpose:
##     Write out changes (if any) to the database.
##   Usage:
##     $ref->commit( [ 'row'  => row_number ] );
##   Return Values:
##     1 on success, undef on failure.
###############################################################################
sub commit {
    my($self) = shift;
    if (! ref($self)) {
        return(undef);
    }
    my(%args) = @_ || ( 'row' => 0 );
    my($column, $first, $sql, @columnlist);

    ## Let's check that the row we've been asked to commit ctually exists
    ## in the object.
    if (! defined($self->{'values'}->[$args{'row'}])) {
        $self->_debug(2, "No such row (" . $args{'row'} . ") to commit");
        return(undef);
    }

    ## If nothing has changed, we know there's nothing to do.
    if ((! defined($self->{'changed'}->[$args{'row'}]))
      || ($#{$self->{'changed'}->[$args{'row'}]} < 0)) {
        $self->_debug(1, "nothing changed for row " . $args{'row'} . "!");
        return(1);
    }

    ## If it's already in the database, we'll be constructing an UPDATE query.
    if ($self->{'in_database'}->[$args{'row'}]) {
        $first = 1;
        my($where) = $self->_unique_where($args{'row'}, []);
        if (! defined($where)) {
            $self->_debug(2, "Can't UPDATE row: " . $args{'row'});
            return(undef);
        }

        $sql = "UPDATE " . $self->{'table'} . " SET ";
        foreach $column (@{$self->{'changed'}->[$args{'row'}]}) {
            if (! $first) {
                $sql .= ", ";
            } else {
                $first = 0;
            }
            $sql .= $column . " = ";
            if ($self->_cprop($column, 'quoted')) {
                 if ($self->{'values'}->[$args{'row'}]->{$column} eq 'NULL') {
                     $sql .= 'NULL';
                 } else {
                     $sql .= $self->{'db'}->quote($self->{'values'}->[$args{'row'}]->{$column});
                 }
            } else {
                 $sql .= $self->{'values'}->[$args{'row'}]->{$column};
            }
        }
        $sql .= " WHERE " . $where;
    ## If it's not already in the database, we'll construct an INSERT query.
    } else {
        $first = 1;
        $sql = "INSERT INTO " . $self->{'table'} . " (";
        foreach $column (keys(%{$self->{'columns'}})) {
            ## Foreign and Special columns are skipped in inserts, sorry.
            if (($self->_cprop($column, 'foreign'))
                  || ($self->_cprop($column, 'special'))) {
                next;
            }
            ## Figure out which columns we'll be inserting.
            ## Columns which are allowed to be null are only inserted if they
            ##  have a value.  Columns which are not allowed to be null have
            ##  either their current value or default value inserted - if
            ##  neither exists, we'll return undef rather than cause a DB error.
            if ($self->_cprop($column, 'null')) {
                if (defined($self->{'values'}->[$args{'row'}]->{$column})) {
                    if (! $first) {
                        $sql .= ", ";
                    } else {
                        $first = 0;
                    }
                    $sql .= $column;
                    push(@columnlist, $column);
                }
            } else {
                if (! defined($self->{'values'}->[$args{'row'}]->{$column})) {
                    if (defined($self->_cprop($column, 'default'))) {
                        if (! $first) {
                            $sql .= ", ";
                        } else {
                            $first = 0;
                        }
                        $sql .= $column;
                        push(@columnlist, $column);
                    } else {
                        $self->_debug(2, "A value is required for $column in "
                                       . "row " . $args{'row'} . " in order to "
                                       . "commit");
                        return(undef);
                    }
                } else {
                    if (! $first) {
                        $sql .= ", ";
                    } else {
                        $first = 0;
                    }
                    $sql .= $column;
                    push(@columnlist, $column);
                }
            }
        }
        $sql .= ") VALUES (";
        $first = 1;
        ## Now add the values for each inserted column, based on the order
        ## in the constructed @columnlist.
        foreach $column (@columnlist) {
            if (! $first) {
                $sql .= ", ";
            } else {
                $first = 0;
            }
            if (defined($self->{'values'}->[$args{'row'}]->{$column})) {
                if ($self->_cprop($column, 'quoted')) {
                    if ($self->{'values'}->[$args{'row'}]->{$column} eq 'NULL') {
                        $sql .= 'NULL';
                    } else {
                        $sql .= $self->{'db'}->quote($self->{'values'}->[$args{'row'}]->{$column});
                    }
                } else {
                    $sql .= $self->{'values'}->[$args{'row'}]->{$column};
                }
            } else {
                my($default) = $self->_cprop($column, 'default');
                if ($self->_cprop($column, 'quoted')) {
                    if ($default eq 'NULL') {
                        $sql .= 'NULL';
                    } else {
                        $sql .= $self->{'db'}->quote($default);
                    }
                } else {
                    $sql .= $default;
                }
            }
        }
        $sql .= ")";
    }
    $self->_debug(1, "$sql");

    ## Run the query.
    my($st);
    if (! ($st = $self->{'db'}->prepare($sql))) {
        $self->_debug(2, "Error preparing SQL");
        return(undef);
    }
    if (! $st->execute()) {
        $self->_debug(2, "Error executing SQL");
        return(undef);
    }
    @{$self->{'changed'}->[$args{'row'}]}  = ();
    $self->{'in_database'}->[$args{'row'}] = 1;

    ## Get the insertid() from the last inserted autoincrement key,
    ## if any - and store it (god DAMN that's ugly!)
    foreach $column (keys(%{$self->{'columns'}})) {
        if (($self->_cprop($column, 'autoincrement')) &&
           (! defined($self->{'values'}->[$args{'row'}]->{$column}))) {
            $self->{'values'}->[$args{'row'}]->{$column} = $st->{'insertid'};
            last;
        }
    }

    return(1);
}
### end commit ################################################################



###############################################################################
## remove
##   Purpose:
##     Remove a row from the database (!!!!!)
##   Usage:
##     $obj->remove( [ row => rownum ] );
##   Return Values:
##     1 on success, undef on failure.
###############################################################################
sub remove {
    my($self) = shift;
    ## Not a class method!
    if (! ref($self)) {
        return(undef);
    }

    my(%args) = @_;
    my($row) = $args{'row'} || 0;
    my($sql);

    ## Generate a good WHERE clause
    my($where) = $self->_unique_where($row, []);
    if (! defined($where)) {
        $self->_debug(2, "Can't DELETE row: $row");
        return(undef);
    }

    ## Build a DELETE statement.
    $sql = "DELETE FROM " . $self->{'table'} . " WHERE " . $where;

    $self->_debug(1, "$sql");

    ## And run it.
    if (! $self->{'db'}->do($sql)) {
        $self->_debug(2, "Error executing SQL");
        return(undef);
    }

    ## Well, just in case this object gets re-committed... might it
    ## be better to explicitly undef myself?
    $self->{'in_database'}->[$row] = 0;

    return(1);
}
###############################################################################



###############################################################################
## get
##   Purpose:
##     Retrieve an attribute value from this object
##   Usage:
##     $value = $obj->get(  column  =>  'column_name',
##                        [ row    =>  row_number ] );
##   Return Values:
##     The current value of the column, or undef if there's a problem.
###############################################################################
sub get {
    my($self) = shift;

    ## Not a class method!
    if (! ref($self)) {
        return(undef);
    }
    my(%args) = @_;

    ## Did we get a 'column' argument?
    if (! defined($args{'column'})) {
        $self->_debug(2, "column parameter to get() is mandatory");
        return(undef);
    }
    if (! defined($args{'row'})) {
        $args{'row'} = 0;
    }

    ## Does this column exist?
    if (! $self->_check_columns([$args{'column'}])) {
        $self->_debug(2, "Column doesn't exist: " . $args{'column'});
        return(undef);
    }

    ## Does this row exist?
    if (! defined($self->{'values'}->[$args{'row'}])) {
        $self->_debug(2, "Row doesn't exist: " . $args{'row'});
        return(undef);
    }

    ## Return the value.
    return($self->{'values'}->[$args{'row'}]->{$args{'column'}});
}
### end get ###################################################################



###############################################################################
## set
##   Purpose:
##     Give values to one or more attributes of this object
##   Usage:
##     $obj->set( change  => { 'column1'  =>  'value1',
##                             'column2'  =>  'value2' },
##                [ row   =>  row_number ] );
##   Return Values:
##     1 on success, undef on failure.
###############################################################################
sub set {
    my($self) = shift;
    ## Not a class method
    if (! ref($self)) {
        return(undef);
    }
    my(%args) = @_;
    my($column);
    $args{'row'} ||= 0;

    ## Ensure that we have a valid row in $args{'row'}.
    if (! defined($self->{'in_database'}->[$args{'row'}])) {
        $self->_debug(2, "Invalid row: " . $args{'row'});
        return(undef);
    }

    ## Have we got a change argument?
    if (! defined($args{'change'})) {
        $self->_debug(2, "change parameter to set() is mandatory");
        return(undef);
    }

    ## Verify that the columns named to be updated actually exist, and are
    ## allowed to be changed...
    foreach $column (keys(%{$args{'change'}})) {
        if (! defined($self->{'columns'}->{$column})) {
            $self->_debug(2, "Attempt to modify nonexistent column: $column");
            return(undef);
        }
        if ($self->_cprop($column, 'immutable')) {
            $self->_debug(2, "Attempt to modify immutable column: $column");
            return(undef);
        }
        if ($self->_cprop($column, 'foreign')) {
            $self->_debug(2, "Attempt to modify foreign column: $column");
            return(undef);
        }
        if ($self->_cprop($column, 'special')) {
            $self->_debug(2, "Attempt to modify special column: $column");
            return(undef);
        }
    }

    ## Make the changes.
    foreach $column (keys(%{$args{'change'}})) {
        if ((! defined($self->{'values'}->[$args{'row'}]->{$column})) || ($args{'change'}->{$column} ne $self->{'values'}->[$args{'row'}]->{$column})) {
            if (($self->_cprop($column, 'null'))
              && ($args{'change'}->{$column} eq '')) {
                $self->{'values'}->[$args{'row'}]->{$column} = 'NULL';
                push(@{$self->{'changed'}->[$args{'row'}]}, $column);
            } else {
                $self->{'values'}->[$args{'row'}]->{$column} = $args{'change'}->{$column};
                push(@{$self->{'changed'}->[$args{'row'}]}, $column);
            }
        }
    }

    return(1);
}
### end set ###################################################################



###############################################################################
## load_related
##   Purpose:
##     To return table objects representing related tables.
##   Usage:
##     $obj2 = $obj->load_related( 'type' => 'table_class_string',
##                                 'row'  => row_to_relate_to,
##                                 %load_arguments );
##   Return Values:
##     Returns some new blessed pseudohash on success; undef on failure.
###############################################################################
sub load_related {
    my($self) = shift;

    ## Not a class method!
    if (! ref($self)) {
        return(undef);
    }

    ## Argument parsing.
    my(%args)  = @_;
    my($class) = $args{'type'} || return(undef);
    my($row)   = $args{'row'}  || 0;

    ## Is there really a related class of this name?
    if (! defined($self->{'related'}->{$class})) {
        $self->_debug(2, "Never heard of class $class, sorry");
        return(undef);
    }

    ## Leave no traces...
    delete($args{'row'});
    delete($args{'type'});

    ## A quick substitution (the relationship between the foreign table
    ## and the local table is defined by the key/values pairs in 
    ## $self->{'related'}->{$class}.)
    my($where);
    foreach $where (keys(%{$args{'where'}})) {
        if (defined($self->{'related'}->{$class}->{$where})) {
            $args{'where'}->{$where} = $self->{'values'}->[$row]->{$self->{'related'}->{$class}->{$where}};
        }
    }

    ## Be nice to the poor end user ;)
    if (!defined($args{'db'})) {
        $args{'db'} = $self->{'db'};
    }

    ## And voila!
    return($class->load(%args));
}
### end load_related ##########################################################



###############################################################################
## num_rows
##   Purpose:
##     Return the number of rows in this object (actually, the index of the
##     highest row.)
##   Usage:
##     $number = $obj->num_rows();
##   Return Values:
##     index of highest row on success, undef on failure.
###############################################################################
sub num_rows {
    my($self) = shift;
    if (! ref($self)) {
        return(undef);
    }
    return($self->{'num_rows'});
}
### end num_rows ##############################################################


###############################################################################
## query_rows
##   Purpose:
##     Return the total number of rows that were returned by the query, which
##     can be different from the number of rows in the object.
##   Usage:
##     $number = $obj->query_rows();
##   Return Values:
##     number of rows (counting from zero) query returned.
###############################################################################
sub query_rows {
    my($self) = shift;
    if (! ref($self)) {
        return(undef);
    }
    return($self->{'query_rows'});
}
### end query_rows ############################################################



###############################################################################
## db
##   Purpose:
##     Return the database handle stored by this object.
##   Usage:
##     $db = $obj->db()
##   Return Values:
##     db handle on success, undef on failure.
###############################################################################
sub db {
    my($self) = shift;
    if (! ref($self)) {
        return(undef);
    }

    return($self->{'db'});
}
### end db ####################################################################



###############################################################################
## columns
##   Purpose:
##     Return a list of columns which are defined in this object
##   Usage:
##     @columns = $obj->columns();
##   Return Values:
##     An array of column names
###############################################################################
sub columns {
    my($self) = shift;
    if (! ref($self)) {
        return(undef);
    }

    my(@columns) = keys(%{$self->{'columns'}});
    return(\@columns);
}
### end columns ###############################################################



###############################################################################
## count
##   Purpose:
##     Count the number of columns matching a where clause
##   Usage:
##     $count = $obj->count( [ where => { key => value } ] );
##   Return Values:
##     A count of the number of matching rows, or undef.
###############################################################################
sub count {
    my($self) = shift;
    if (! ref($self)) {
        return(undef);
    }

    my(%args) = @_;

    my($sql) = "SELECT COUNT(*) AS count FROM " . $self->{'table'};
    $sql    .= $self->_where($args{'where'}, []);

    ## That's some fancy SQL you've got there!
    $self->_debug(1, "$sql");

    ## Perform the database query
    my($st);
    if (! ($st = $self->{'db'}->prepare($sql))) {
        $self->_debug(2, "Error preparing SQL");
        return(undef);
    }
    if (! $st->execute()) {
        $self->_debug(2, "Error executing SQL");
        $st->finish();
        return(undef);
    }

    return($st->fetchrow_hashref()->{'count'});
}
### end count #################################################################



###############################################################################
## debug_level
##   Purpose:
##     Set the debugging level.
##   Usage:
##     $table->debug_level( [ level => $level ] );
##   Return Values:
##     The value of $self->{'debug_level'} (after changing, if any change was
##     made).
###############################################################################
sub debug_level {
    my($self) = shift;
    if (! ref($self)) {
        return;
    }

    my(%args)  = @_;
    my($level) = $args{'level'} || return($self->{'debug_level'});
    return($self->{'debug_level'} = $level);
}
### end debug_level ###########################################################



###############################################################################
## _debug
##   Purpose:
##     Debugging output function.
##   Usage:
##     $table->_debug($priority, "error!");
##   Notes:
##     Priority should be from 0 to 2, with 0 being detailed debugging info,
##     1 being informational stuff, and 2 being errors.
###############################################################################
sub _debug {
    my($self) = shift;
    if (! ref($self)) {
        return(undef);
    }

    my($priority) = shift;

    if ($self->{'debug_level'} <= $priority) {
        print STDERR "@_\n";
    }
}
### end debug #################################################################



###############################################################################
## _cprop
##   Purpose:
##     Retrieve a column's property
##   Usage:
##     $table->_cprop($column, $property_name);
##   Return Values:
##     Returns undef if there is a problem, or the property doesn't exist.
##     Otherwise returns the value of the property.
###############################################################################
sub _cprop {
    my($self) = shift;
    if (! ref($self)) {
        return(undef);
    }

    my($column)   = shift || return(undef);
    my($property) = shift || return(undef);

    if (defined($self->{'columns'}->{$column}->{$property})) {
        return($self->{'columns'}->{$column}->{$property});
    } else {
        return(undef);
    }
}
### end _cprop ################################################################



###############################################################################
## _unique_where
##   Purpose:
##     Create a WHERE clause based on the defined unique key combinations and
##     the currently loaded data.
##   Usage:
##     $table->_unique_where($row);
##   Return Values:
##     Returns a string containing a valid WHERE clause which uniquely
##     identifies this row in the database.
###############################################################################
sub _unique_where {
    my($self) = shift;
    if (! ref($self)) {
        return(undef);
    }

    my($row)        = shift || 0;
    my($columnlist) = shift || [];

    if (! defined($self->{'in_database'}->[$row])) {
        $self->_debug(2, "Row doesn't exist: $row");
        return(undef);
    }

    my($sublist, $column, $extra);

  unique_combo:
    foreach $sublist (@{$self->{'unique_keys'}}) {
        my($where) = '';
        my($first) = 1;
        foreach $column (@{$sublist}) {
            ## Each column in the combo must:
            ## have a value
            if (! defined($self->{'values'}->[$row]->{$column})) {
                $self->_debug(1, "$column in $row has no value");
                next unique_combo;
            }
            ## not have been modified
            foreach (@{$self->{'changed'}->[$row]}) {
                if ($_ eq $column) {
                    $self->_debug(1, "$column in $row has been modified");
                    next unique_combo;
                }
            }

            ## Okay...
            if ($first) {
                $first = 0;
            } else {
                $where .= " AND ";
            }
            $where .= $self->{'table'} . "." . $column . " = ";
            $where .= $self->{'values'}->[$row]->{$column};
        }
        if ((defined(@{$columnlist})) && (scalar(@{$columnlist}) > 0)) {
            foreach $column (@{$columnlist}) {
                if ($extra = $self->_cprop($column, 'foreign')) {
                    if (! $first) {
                        $where .= " AND ";
                    }
                    $first = 0;
                    $where .= $extra->{'table'};
                    $where .= "." . $extra->{'rkey'} . " = ";
                    $where .= $self->{'table'} . "." . $extra->{'lkey'};
                }
                if ($extra = $self->_cprop($column, 'special')) {
                    if (defined($extra->{'where'})) {
                        if (! $first) {
                            $where .= " AND ";
                        }
                        $first = 0;
                        $where .= $extra->{'where'}
                    }
                }
            }
        }
        return($where);
    }

    $self->_debug(2, "No unique combinations currently loaded.");
    return(undef);
}
### end _unique_where #########################################################



###############################################################################
## _columns                               
##   Purpose:
##     Generate the column list of an SQL query.
##   Usage:                             
##     $table->_columns( [ 'column_1', 'column_2' ]);
##   Return Values:                     
##     Returns the generated SQL snippet.
###############################################################################
sub _columns {
    my($self) = shift;
    if (! ref($self)) {
        return(undef);
    }

    my($columnlist) = shift;
    my($sql)        = '';
    my($first)      = 1;
    my($column, $extra);

    if ((defined(@{$columnlist})) && (scalar(@{$columnlist}) > 0)) {
        foreach $column (@{$columnlist}) {
            if (! $first) {
                $sql .= ", ";
            }
            $first = 0;
            if ($extra = $self->_cprop($column, 'foreign')) {
                $sql .= $extra->{'table'};
                if (defined($extra->{'actual_column'})) {
                    $sql .= "." . $extra->{'actual_column'};
                    $sql .= " AS $column";
                } else {
                    $sql .= "." . $column;
                }
            } elsif ($extra = $self->_cprop($column, 'special')) {
                $sql .= $extra->{'select'};
            } else {
                $sql .= $self->{'table'} . "." . $column;
            }
        }
    } else {
        $sql .= "*";
    }

    return($sql);
}
### end _columns ##############################################################



###############################################################################
## _where
##   Purpose:
##     Generate the WHERE part of an SQL query.
##   Usage:
##     $table->_where( { 'column' => 'value', ... },
##                     [ 'column_1', 'column_2' ]);
##   Return Values:
##     Returns the generated SQL snippet.
###############################################################################
sub _where {
    my($self) = shift;
    if (! ref($self)) {
        return(undef);
    }

    my($where)      = shift;
    my($columnlist) = shift;
    my($sql)        = ' WHERE ';
    my($first)      = 1;
    my($column, $extra);

    foreach $column (keys(%{$where})) {
        if (! $first) {
            $sql .= " AND ";
        }
        $first = 0;

        if ($extra = $self->_cprop($column, 'foreign')) {
            $sql .= $extra->{'table'};
            if (defined($extra->{'actual_column'})) {
                $sql .= "." . $extra->{'actual_column'};
            } else {
                $sql .= "." . $column;
            }
        } else {
            $sql .= $self->{'table'} . "." . $column;
        }
        if ($where->{$column} eq 'IS NULL') {
            $sql .= " IS NULL";
        } else {
            $sql .= " = ";
            if ($self->_cprop($column, 'quoted')) {
                $sql .= $self->{'db'}->quote($where->{$column});
            } else {
                $sql .= $where->{$column};
            }
        }
    }
    if (defined(@{$columnlist})) {
        foreach $column (@{$columnlist}) {
            if ($extra = $self->_cprop($column, 'foreign')) {
                if (! $first) {
                    $sql .= " AND ";
                }
                $first = 0;
                $sql .= $extra->{'table'};
                $sql .= "." . $extra->{'rkey'} . " = ";
                $sql .= $self->{'table'} . "." . $extra->{'lkey'};
            }
            if ($extra = $self->_cprop($column, 'special')) {
                if (defined($extra->{'where'})) {
                    if (! $first) {
                        $sql .= " AND ";
                    }
                    $first = 0;
                    $sql .= $extra->{'where'}
                }
            }
        }
    }
    if ($first) {
        return '';
    } else {
        return $sql;
    }
}
### end _where ################################################################



###############################################################################
## _from
##   Purpose:
##     Generate the FROM section of an SQL query
##   Usage:
##     $table->_from([ 'column_1', 'column_2' ]);
##   Return Values:
##     Returns a string containing the SQL snippet generated.
###############################################################################
sub _from {
    my($self) = shift;
    if (! ref($self)) {
        return(undef);
    }

    my($columnlist) = shift;
    my($sql)        = ' FROM ' . $self->{'table'};
    my($column, $extra);

    if (defined(@{$columnlist})) {
        foreach $column (@{$columnlist}) {
            if ($extra = $self->_cprop($column, 'foreign')) {
                if (defined($extra->{'actual_table'})) {
                    $sql .= " JOIN " . $extra->{'actual_table'};
                    $sql .= " AS " . $extra->{'table'}
                } else {
                    $sql .= " JOIN " . $extra->{'table'};
                }
            }
            if ($extra = $self->_cprop($column, 'special')) {
                if (defined($extra->{'join'})) {
                    if ($extra->{'join'} !~ /join/i) {
                        $sql .= " JOIN ";
                    }
                    $sql .= " " . $extra->{'join'};
                }
            }
        }
    }
    return($sql);
}
### end _from #################################################################



###############################################################################
## _check_columns
##   Purpose:
##     Verify that a given list of columns are defined in the current table
##     description.
##   Usage:
##     $table->_check_columns([ 'column_1', 'column_2']);
##   Return Values:
##     True if the column list passes the test, undef if it fails.
###############################################################################
sub _check_columns {
    my($self) = shift;
    if (! ref($self)) {
        return(undef);
    }

    my($columnlist) = shift || return undef;
    my($column);

    foreach $column (@{$columnlist}) {
        ($column eq '*') && next;
        if (! defined($self->{'columns'}->{$column})) {
            return undef;
        }
    }
    return 1;
}
### end _check_columns ########################################################

1;

__END__

=head1 NAME

DBIx::Table - Class used to represent DBI database tables.

=head1 SYNOPSIS

=head2 To make it useful:

  package SUBCLASS;
  @ISA = qw(DBIx::Table);
  sub describe {
      my($self) = shift;
      $self->{'table'}       = $table_name;
      $self->{'unique_keys'} = [ [ $column, ... ], ... ];
      $self->{'columns'}     = { $col_name => { %col_options },
                                 [ ... ]
                               };
    [ $self->{'related'}     = { $class_name => { %relationship },
                                 [ ... ]
                               }; ]
  }

=head2 To use the useful object:

  $table = load SUBCLASS( db      => $dbi_object,
                        [ where   => { $column => $value, ... }, ]
                        [ columns => [ $column1, $column2 ], ]
                        [ index   => $index, ]
                        [ count   => $count, ]
                        [ groupby => $groupby, ]
                        [ orderby => ['+'|'-'] . $column ]);
  $table = create SUBCLASS( db => $dbi_object);

  $new_table  = $table->load_related( type => $classname,
                                      row  => $row,
                                    [ %where_arguments ] );
  $num_rows   = $table->num_rows();
  $query_rows = $table->query_rows();
  $columns    = $table->columns();
  $db         = $table->db();
  $level      = $table->debug_level( [ level => $level ] );
  $value      = $table->get( column => $column, [ row => $row ] );
  $retval     = $table->set( change => { $column => $value, [ ..., ] },
                             [ row => $row ] );
  $retval     = $table->refresh( columns = [ $column1, $column2 ],
                                 [ row => $row ] );
  $retval     = $table->commit( [ row => $row ] );
  $retval     = $table->remove( [ row => $row ] );
  $count      = $table->count( [ where => { $column => $value, ... } ]

=head1 DESCRIPTION

DBIx::Table is a class designed to act as an abstraction layer around a fairly
large subset of SQL queries.  It is called 'Table' because it is primarily
designed such that a single subclass provides an object-oriented interface to
a single database table.  The module is flexible enough, though, that it can 
be used to abstract most any schema in a way that is comfortable to the perl
coder who is not familiar with the underlying schema, or even SQL.

As the synopsis above points out, this class is not useful when simply used by
itself.  Instead, it should be subclassed.  The subclass follows a particular
syntax for describing the structure of the table, which the Table module
uses internally to control its behavior.

The subclass can then be used to access the underlying data, with the Table
module taking care of writing the actual SQL.  The current version can write
SELECT, UPDATE, INSERT and DELETE statements.
Depending on the complexity of the definition, it can also do joins across
multiple tables and intelligently load related table objects.

The rest of the documentation is split: first, how to create a useful subclass.
Second, constructors and access methods on the subclass.  Third, some examples.
Without further ado...

=head2 Subclassing

See the perltoot(1) and perlobj(1) manuals if you don't know how to create
a class, subclass, or if you don't understand inheritance or overriding
inherited functions.

Every subclass of DBIx::Table is required to provide a method called "describe",
which, at a minimum, needs to provide some clues as to the form of the
underlying data.  This is done by modifying a few key parts of the data stored
in the object itself:

=over 3

    my($message)  = "@_";
=item B<$self-E<gt>{'table'}>

This should contain a string; the name of the table from which data is going
to be retrieved.  This should be the primary table in the case of complex
classes joining from multiple tables - this table name will be used for
columns which do not provide any other table name.

=item B<$self-E<gt>{'unique_keys'}>

If you plan on using the commit() or remove() methods, you'll need to provide
at least one unique key combination.  This parameter takes a reference to an
array of references to arrays of strings.  The listed strings in the second
level array are the names of columns which, taken in conjunction, are guaranteed
to be unique in the database.  These are tried in order, so put them in order
of preference.

=item B<$self-E<gt>{'columns'}>

This should contain a reference to a hash, where most of the interesting bits
of configuration go.  The hash referenced should be keyed by column names, and
have values consisting of hash references.  These nested hashes should contain
configuration options for the column in question.  This all sounds pretty hairy,
but in practice it's really not so bad - see the Examples section below.  Here
are the available column options:

=over 6

=item null

DBIx::Table only cares if this is defined or not defined.  If it is defined, a
commit() call will fail if a value for this column is not set() first, or
no default is supplied.  This only applies to local columns.

=item quoted

DBIx::Table only cares if this is defined or not defined.  If it is defined,
data which is set() to this column will be quoted using $self->{'db'}->quote(),
the quote method on the DBI object passed into the constructor.

=item immutable

DBIx::Table only cares if this is defined or not defined.  If it is defined,
trying to set() a value to this column will cause set() to fail.  Immutability
is, for now at least, implicit on all "foreign" and "special" columns - i.e.
you can't update foreign data!

=item autoincrement

DBIx::Table only cares if this is defined or not defined.  If it is defined,
some magic will take place to ensure that, after an INSERT, the autoincremented
value is correctly stored in the object.  This is probably MySQL specific.

=item default

The contents of this parameter will be used by commit() to UPDATE or INSERT
data on a column without the null attribute.  It will be quoted if the quoted
attribute is set.

=item foreign

This contains another hash reference.  It is used to define the
simplest case foreign columns.  The hash requires the keys 'table', 'lkey', and
'rkey' - the name of the table to join, relationship column name in the joined
table, and relationship column name in the local table, respectively.
Optionally, it can also take 'actual_table' and 'actual_column' keys, with
their values being the real names of the foreign table and column.  This can
be used to fetch the same column from a table more than once, based on
different WHERE clauses.  See the Examples section to visualize this in action.

=item special

This contains yet another hash reference (doh!)  It is used to define columns
which defy the abstraction currently provided by DBIx::Table.  Most frequently,
this will be any column which has functions act on it, and/or complicated joins.
The recognized keys are 'select', 'join', 'where' and 'groupby'.  The values
for each of these keys are raw SQL pieces, which will be stuffed into the
appropriate place in the generated SQL.  One important note is that the
constructor expects the column name defined in $self->{'columns'} to match
the name of the column where this data is returned by the SQL statement, so
you will want to always add 'AS column_name' to the end of the select chunk of
SQL.  And again, check out the Examples to help visualize how this works.

=back

=item B<$self-E<gt>{'related'}>

This is not mandatory!  If defined, it should contain a reference to a hash,
keyed by package names.  The values are hash references, keyed by column
names from the foreign package, with values being the column name of a local
column.  This is used by the load_related convenience method - see the
description of this method below, as well as the Examples section, to get more
of a grasp of how this works.

=back

=head2 Methods

All of the public methods use hash-style arguments.  I've tried to be
consistent and obvious in the naming of arguments.

The only class methods are the constructors, all other methods are strictly
object methods (i.e. you can't call SUBCLASS::get(...), you have to call
$subclass_object->get(...)).

All methods return undef if they fail.

General issues aside, here are the descriptions of the specific methods:

There are two constructors:

=over 3

=item B<load()>

This is the primary constructor and SELECT statement generator.  It takes a
bunch of arguments, though only the db argument is mandatory:

=over 6

=item db

This argument should contain a reference to a DBI object.  It is assumed to
be connected and valid for the lifetime of the object to which it is passed.

=item where

This argument should contain a hash reference, with keys being column names and
values being the value that column must equal.  As a bonus hack, if the value
is the string 'IS NULL', it'll work as you want it to (unless you're actually
looking for the string 'IS NULL' in the database, in which case you're screwed.)
If this argument is excluded, no WHERE clause will be used (all rows will be
returned.)

=item columns

This argument should contain an array reference.  The elements of the array
should be column names, or the special string '*'.  It is important to realize
that columns with the 'foreign' or 'special' attributes are not loaded if this
argument is left out of the load() call.  The special string '*' is expanded
to all columns which are not 'foreign' or 'special'.  If this argument is left
out, a literal '*' will go in the SQL generated, indicating that all local
columns in this table should be loaded.

=item index

This argument should contain a numeric scalar, which is used to limit
the amount of data stored (but not I<queried>!) by the object returned by
load().  It is the number of the first row to store, starting from zero.

=item count

This argument should contain a numeric scalar, which is also used to limit
the amount of data stored (but, again, not queried!) by load().  This is
a zero-based count of the maximum number of rows to store.

=item groupby

This argument should contain a string scalar.  It is the name of a column, and
it causes the addition of a GROUP BY column_name clause to the end of the SQL
generated.

=item orderby

This argument should contain a string scalar, the name of a column which to
be used to sort the returned data.  It causes the addition of an ORDER BY
column_name clause to the SQL generated.  Bonus hack: if you prepend a "+" to
the column name, the clause has "ASC" appended to it, and if you prepend a "-"
to the column name, the clause has "DESC" appended to it.

=back

=item B<create()>

This simple constructor builds and returns an empty object.  It is useful
for inserting new data into a table.  It is also useful for creating an
empty instance of the object with which to use the count() method.  It takes
only one argument, 'db', which is identical to the 'db' argument to load(),
described above.

=back

Two methods for using the data in the object:

=over 3

=item B<get()>

This method is used to fetch data from the object.  It takes only two possible
arguments; only the 'column' argument is mandatory.

=over 6

=item column

This should contain the name of the column to retrieve.  At the moment, you
can only retrieve one value at a time.

=item row

This should contain the number of the row to retrieve data from.  Rows in the
object are I<always> indexed by 0.  If this argument is excluded, it defaults
to 0.

=back

=item B<set()>

This method is used to change data in the object.  It has only two possible
arguments.  Only the 'change' argument is mandatory, and the 'row' argument
is identical to that described in get() above.

=over 6

=item change

This should contain a hash reference.  The keys of the hash should be column
names, and the values should be the values you wish to place in those columns.
You can change as many columns as you want at once, but remember that 'foreign',
'special' and 'immutable' columns cannot be changed.

=back

=back

Three methods can make additional SQL queries based on the current data:

=over 3

=item B<refresh()>

This method can perform additional SELECT queries to the database, using the
data already loaded to ensure that the new data relates to the existing row.
It takes a mandatory 'columns' argument, an array reference containing column
names to load.  It can also take a 'row' argument, as described under get()
above.

=item B<commit()>

This method is responsible for writing UPDATE or INSERT SQL statements.  It
takes one optional argument, 'row', which is identical to the 'row' argument
described under get() above.

Please be careful with this method, as it has only been tested for fairly
simple cases.

=item B<remove()>

This method writes DELETE SQL statements, attempting to remove the current row
from the database permanently.  It takes one optional argument, 'row', which
is identical to the 'row' argument described under get() above.

Please be careful with this method, as it has only been tested for fairly
simple cases.

=back

Several methods can be used to get meta-data about the object, and the
data retrieved, and configure behavior of the object:

=over 3

=item B<num_rows()>

Returns the number of rows stored in the current object.

=item B<query_rows()>

Returns the number of rows returned by the last query (this may be different
from num_rows() if 'index' or 'count' parameters to load() were used).

=item B<columns()>

Returns a reference to an array containing the names of all the columns in
the object.  Not only the ones with data in them, mind you!  I<All> column
names are returned.

=item B<db()>

Returns a reference to the database object that is being used.

=item B<debug_level()>

This takes a 'level' parameter, with a numeric value.  The range from 0 to 2
is significant: 0 is trivial debugging information, 1 is informational messages,
and 2 is errors.  Debugging information is only printed (to STDERR) if the
debug_level is set to the priority level of the message or lower.  This function
can also be used with no arguments to return the current debug_level.

=back

And a couple of "miscellaneous" utility functions:

=over 3

=item B<count()>

This is a function for generating count(*) style SELECT statements.  It does
not store the return from the query; instead, it returns it to the caller.  It
takes an optional 'where' argument, identical to the one described under load().

=item B<load_related()>

This is a utility function for constructing objects from different classes,
which are related to the current class.  It takes two arguments of its own,
but only the 'type' argument is mandatory:

=over 6

=item type

This should contain the name of the class from which to load a new object.

=item row

This should contain the row number to which the new object should be related.
It defaults to 0.  The row number is used in the substitution process
described below.

=back

All other arguments will be passed on to the load() constructor for the class
passed in in 'type'.  It is not necessary to provide a 'db' argument; it will
simply pass on the one it already has.  And finally, the real nicety provided
by load_related is that it will check the 'where' argument (if any) and will
use the information in $self->{'related'} to substitute values.  So you can
say where => { 'that_column' => 'this_column' }, and load_related will convert
the literal 'this_column' into the current value of this_column.

=back

=head2 Examples

These examples are simple but are designed to show you how this module can
be used.  They progress from table descriptions to complete subclasses to
usage, including showing the SQL that is output.

Beginning with two tables (as you would create them with MySQL).  First, a
simple users table, very straightforward:

  CREATE TABLE users (
    uid      INT UNSIGNED NOT NULL AUTO_INCREMENT,
    email    VARCHAR(70)  NOT NULL,
    password VARCHAR(10)  NOT NULL,
    PRIMARY KEY(uid),
    UNIQUE (uid),
  );

Second, a feedback table.  This table is complexly related to the users table;
each user can both send and receive multiple feedback, so both the to_uid and
from_uid columns point back to the users table.

  CREATE TABLE feedback (
    fid      INT UNSIGNED                   NOT NULL AUTO_INCREMENT,
    to_uid   INT UNSIGNED                   NOT NULL,
    from_uid INT UNSIGNED                   NOT NULL,
    time     DATETIME                       NOT NULL,
    type     ENUM('good', 'bad', 'neutral') NOT NULL,
    text     VARCHAR(100)                   NOT NULL,
    PRIMARY KEY (fid),
    INDEX (to_uid),
    INDEX (from_uid),
    UNIQUE uid_combo (to_uid, from_uid)
  );

Okay, now we need to create objects to represent them.  For users, I want to
be able to fetch the counts of the feedback recieved by the user in question
for each of the three feedback types, which requires 'special' columns:

  package User;
  use strict;
  use DBIx::Table;
  @User::ISA = qw(DBIx::Table);

  sub describe {
      my($self) = shift || return(undef);

      $self->{'table'}       = 'users';
      $self->{'unique_keys'} = [ ['uid'] ];
      $self->{'columns'}     = {
        'uid'        => { 'immutable'     => 1,
                          'autoincrement' => 1,
                          'default'       => 'NULL' },
        'email'      => { 'quoted'        => 1 },
        'password'   => { 'quoted'        => 1 },
        'good_fb'    => { 'special'       => 
           { 'select'  => 'count(fb_g.type) AS good_fb',
             'join'    => 'LEFT JOIN feedback AS fb_g ON (fb_g.type = '
                          . '\'good\' AND fb_g.to_uid = users.uid)',
             'groupby' => 'uid' } },
        'bad_fb'     => { 'special'       =>
           { 'select'  => 'count(fb_b.type) AS bad_fb',
             'join'    => 'LEFT JOIN feedback AS fb_b ON (fb_b.type = '
                          . '\'bad\' AND fb_b.to_uid = users.uid)',
             'groupby' => 'uid' } },
        'neutral_fb' => { 'special'       =>
           { 'select'  => 'count(fb_n.type) AS neutral_fb',
             'join'    => 'LEFT JOIN feedback AS fb_n ON (fb_n.type = '
                          . '\'neutral\' AND fb_n.to_uid = users.uid)',
             'groupby' => 'uid' } }
      };
      $self->{'related'}    = { 'Feedback' => { 'from_uid' => 'uid',
                                                'to_uid'   => 'uid' } };   
  }
  1;

Phew.  Now how about the feedback table.  In this case, we'd like to be
able to fetch the email addresses of both the sender and recipient users in
the same query.  This can be done with 'foreign' columns.  Here's the class:

  package Feedback;
  use strict;
  use DBIx::Table;
  @Feedback::ISA = qw(DBIx::Table);

  sub describe {
      my($self) = shift || return(undef);

      $self->{'table'}       = 'feedback';
      $self->{'unique_keys'} = [ ['fid'] ];
      $self->{'columns'}     = {
        'fid'        => { 'immutable'     => 1,
                          'autoincrement' => 1,
                          'default'       => 'NULL' },
        'to_uid'     => { },
        'from_uid'   => { },
        'time'       => { 'default'       => 'NOW()' },
        'type'       => { 'quoted'        => 1 },
        'text'       => { 'quoted'        => 1 },
        'to_email'   => { 'foreign'       =>
           { 'table'         => 'users_to',
             'lkey'          => 'to_uid',
             'rkey'          => 'uid',
             'actual_table'  => 'users',
             'actual_column' => 'email' } },
        'from_email' => { 'foreign'       =>
           { 'table'         => 'users_from',
             'lkey'          => 'from_uid',
             'rkey'          => 'uid',
             'actual_table'  => 'users',
             'actual_column' => 'email' } }
      };
  }
  1;

Using these is simple enough.  The simplest case would be:

  $obj = load User( db => $db );

which generates the SQL:

  SELECT * from users

Not very intersting.  How about:

  $obj = load User db      => $db,
                   where   => { uid => 1 },
                   columns => [ '*', 'good_fb', 'bad_fb', 'neutral_fb' ];

Which generates the SQL (formatted for viewing ease):

  SELECT      count(fb_g.type) AS good_fb,
              count(fb_b.type) AS bad_fb,
              count(fb_n.type) AS neutral_fb,
              users.password,
              users.email,
              users.uid
  FROM        users
    LEFT JOIN feedback AS fb_g
           ON (fb_g.type = 'good'    AND fb_g.to_uid = users.uid)
    LEFT JOIN feedback AS fb_b
           ON (fb_b.type = 'bad'     AND fb_b.to_uid = users.uid)
    LEFT JOIN feedback AS fb_n
           ON (fb_n.type = 'neutral' AND fb_n.to_uid = users.uid)
  WHERE       users.uid = 1
  GROUP BY    uid

Let's load up all feedback with the associated e-mail addresses, arranged by
descending time sent:

  $obj = load Feedback db      => $db,
                       columns => [ '*', 'to_email', 'from_email' ],
                       orderby => '-time' ;

Generates the SQL (again, formatted):

  SELECT   users_to.email   AS to_email,
           users_from.email AS from_email,
           feedback.type,
           feedback.vs_fid,
           feedback.to_uid,
           feedback.text,
           feedback.from_uid,
           feedback.time
  FROM     feedback
      JOIN users AS users_to
      JOIN users AS users_from
  WHERE    feedback.to_uid = 2
       AND users_to.uid   = feedback.to_uid
       AND users_from.uid = feedback.from_uid
  ORDER BY feedback.time DESC

That seems like enough to get started.

=head1 BUGS

=over 3

=item *

Autoincrement columns are known to be mySQL specific.  There's probably more,
since this has really only been tested with MySQL.  If anyone tries it with
another DBD, I'd love to hear from you!

=item *

In a stupid design oversight, the current incarnation can only automatically
generate "... WHERE foo = bar ..." in SELECT statements, emphasis on the '='.
Sorry!  I'll work on it!

=back

=head1 AUTHOR

J. David Lowe, dlowe@pootpoot.com

=head1 SEE ALSO

perl(1)

=cut
