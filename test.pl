######################### We start with some black magic to print on failure.

use strict;
use vars qw($loaded);

BEGIN { $^W = 1; $| = 1; print "1..1\n"; }
END   {print "not ok 1\n" unless $loaded;}
use DBIx::Table;
$loaded = 1;
print "ok 1\n";

######################### End of black magic.



### package FakeST ############################################################
package FakeST;

sub new {
    my($class) = shift;
    my($self) = {};
    $self->{'returned'} = 0;
    bless($self, $class);
    return $self;
}
 
sub execute {
    my($self) = shift;
    return 1;
}
 
sub finish {
    return 1;
}

sub fetchrow_hashref {
    my($self) = shift;
    if ($self->{'returned'}) {
        return undef;
    } else {
        $self->{'returned'} = 1;
        return { 'id' => 1 };
    }
}
### end package FakeST ########################################################



### package FakeDBI ###########################################################
package FakeDBI;

sub new {
    my($class) = shift;
    my($self) = {};
    bless($self, $class);
    return $self;
}

sub prepare {
    my($st) = new FakeST;
    return $st;
}

sub quote {
}

sub do {
}
### end package FakeDBI #######################################################



### package TestTable #########################################################
package TestTable;

@TestTable::ISA = qw(DBIx::Table);

sub describe {
    my($self) = shift || return(undef);

    $self->{'table'}       = 'test';
    $self->{'unique_keys'} = [ ['id'] ];
    $self->{'columns'}     = { 'id'         => { 'immutable'     => 1,
                                                 'autoincrement' => 1,
                                                 'default'     => 'NULL' }
                             };

    $self->debug_level( level => 0 );

    return 1;
}
### end package TestTable #####################################################



### begin actual test code ####################################################

## create a fake database handle for passing to table objects.
#my($db)    = new FakeDBI;

#my($table) = load TestTable( db => $db );
#if (! defined($table)) {
    #print("not ok 2\n");
#} else {
    #print("ok 2\n");
#}

### end actual test code ######################################################
