# Project Overview

DBConnect is intended to be a self contained tool for "simple" data analysis. The goal is
to be able to write Quasi-SQL in a much looser syntax than standard databases allow, have
this get transpiled into official SQL, execute this SQL against a database (Snowflake),
get results back via ODBC, and do basic data manipulation and summarization in memory
without needing to context switch to Pandas or Excel. 

This project is born out of my day to day frustrations working as a data analyst. Standard
SQL is often needlessly picky (e.g. insisting on Group By statements even when it's clear
what you want to group by) and uses extremely awkward syntax for window functions and CTEs.
Database tools like Datagrip force you to export data to Excel or run a new query even for
simple changes, like dividing one column by another. The Snowflake web UI is so slow that
just sorting 1,000 rows takes multiple seconds. I would like this project to smooth out
these sources of friction so I can more effectively maintain a flow state at work.

This is also intended as a learning project. I am comfortable in Python and Javascript 
but have limited experience working with low-level languages. I do not merely want to
get something roughly working; I want to architect this using good Data-Oriented Design
principles such that I can work with millions of rows without concern. I am highly
inspired by the Handmade Network (https://handmade.network/manifesto) and the work of
Casey Muratori (https://www.computerenhance.com/) and aspire to live up to their examples.

(I am aware this is an ambitious learning project. My hope is that the motivation of being 
able to use this for hours every day will outweigh the demotivation of its difficulty. 
If that proves not to be true, that will itself be a learning experience 🙂)

# Tech stack

-Target the latest stable version of Zig. Since Zig is a pre-release language, I accept
    that this will require rewriting things as the language evolves.

-ODBC is the interface layer between this code and the Snowflake database. I intentionally
    choose to write my own bindings rather than use existing ones.

-Snowflake is the target database. At some point, I may expand the scope to support
    other SQL dialects, but this is out of scope for V1.

# Communication Preferences

-Please do not be sycophantic. You do not need to praise or validate me.

-Please push back against my ideas if you think I am making a mistake, especially when
    it comes to memory management. 

-Since this is a learning project, please err on the side of over-explaining low-level
    best practices and gotchas.

-This is also a learning project around working with coding agents. Please point out
    places where my intention is unclear so I can learn to write better guides.

# Coding Preferences

-Prefer flat, cache-friendly data structures where possible.

-Prefer indices and IDs over pointers where possible.

-In general, use Data-Oriented Design as a North Star. This is the core reason I'm using
    Zig, even though I am much more comfortable programming in Python. PLEASE push back
    on me if I am going down a highly inefficient path.

-Prefer human-readable names over concise ones (e.g. index, not idx or i).

-Use type aliases to communicate intent (e.g. call something a Path, not a []const u8).

-Assume Unix conventions; this does not need to be cross-platform.

-Minimize external dependencies where possible. Ideally, ODBC is the only dependency,
    but others can be added if they solve very complex problems 

-Write integration tests and unit tests that will actually catch difficult bugs, but 
    don't create tons of unit tests for their own sake. Too many tests create friction 
    when changing interfaces, and the shape of this program is still in flux.

# Architecture

-main.zig - This is messier than it should be. Ideally, this hosts a console from which
    a user can load SQL files, transpile them, execute the results, do basic data
    manipulation, etc. Eventually, I would like to include a text editor in this console
    as well to remove one additional source of context switching. 

-common.zig - Reusable helper utilities for things like string manipulation.

-transpilation/ - This folder defines a SQL transpiler which takes in a custom quasi-SQL
    syntax and produces valid formal SQL. It has three steps: `lexing.zig` splits an
    input string into tokens, `parsing.zig` parses those tokens into an internal query
    representation (far more rigid than an AST, although I am open to revisiting this
    design decision), and `transpiler.zig` turns that query representation into valid
    SQL for Snowflake to consume.

-datastores.zig - This defines a "Datastore" object, analogous to a Pandas dataframe.
    Once a query is executed, the results are stored in a "datastore" for in-memory
    manipulation. For example, if there's a Revenue column and a Sessions column, it
    should be trivial to define a new Revenue/Session column as a direct function of
    those two.

-database_connector.zig - Using ODBC under the hood, this provides an interface which 
    takes a SQL query and returns a Datastore representing the results, analogous to 
    Pandas' read_sql() function.


In an ideal world, I would love these components to be more modular and lend themselves 
well to different contexts, e.g. making the transpiler a library that I can call from 
this project or embed in a VSCode extension, allowing this to be run from either the 
command line or a simple GUI, etc. 

## Possible architecture decision: Pseudo "Frame" boundaries

Most of the Data-Oriented Design context I have comes from video games, where it is
natural to think of two kinds of memory lifetimes: memory that lives across a frame
boundary, and "scratch space" that is only used for the current frame. This short-lived
"scratch space" can be set up in a lower friction way, because you don't need to worry
about freeing everything; you just clear it all once you've drawn the frame. This
especially seems like a good fit for string manipulation; it seems silly to worry about
out of memory errors and freeing data when I'm just concatenating strings.  While my 
program does not explicitly have "frames" in the way a game does, I suspect it could
be helpful to set up a similar split between short-term and long-term memory.

# Error Handling

As of April 18, 2026, I have barely thought about proper error handling, and nearly
every problem causes an immediate crash. Ideally, we should gracefully recover from
errors and let the program keep running, especially for trivial "errors" like not being
able to find a config file. I do not yet know the best way to architect this in a
low-level language, since I am so used to thinking about catching Python exceptions. 
I would greatly appreciate guidance here.

# Quasi-SQL Design

The goal of my custom Quasi-SQL language is that it should "do what I mean", which is
inherently somewhat subjective and built around my own idiosyncrasies. Primarily, I 
want it to be more permissive in what it will accept than standard SQL. For example:

```sql
select date, sum(revenue)
from revenue_data
where date >= current_date - 1
where country in (
    'United States',
    'Canada',
    'Australia',
)
```

This is invalid SQL, but unambiguous in intent. I want to combine the two `where` 
clauses into one, I want to remove the invalid trailing comma in the country list,
and I want to group by `date`. I would like to be able to write this and have it
transpiled into valid SQL without any noticeable delay, since manually fixing small
errors like this is a routine source of friction when exploring data.

A standalone table name should transpile into a valid "select * from table" query. 
Additionally, all formal SQL should also be valid input, although I am not concerned
with making transpilation idempotent (for example, I may change `!=` into `<>` or 
introduce different formatting).

While my core goal is to simply allow "sloppier" queries, there are a few pieces of SQL
syntax I would like to totally replace. The first is CTE syntax, which I would like to
replace with an assignment syntax:

Standard SQL:
```sql
with cte_1 as (
    select * from table_1
),

cte_2 as (
    select * from table_3
)

select * 
from cte_1
join cte_2
using (...)
```

Internal Quasi-SQL:
```sql
cte_1 := select * from table_1;

cte_2 := select * from table_2;

select * 
from cte_1
join cte_2
using (...)
```

The second is window functions, especially for the common use case of running totals. I find 
SQL's syntax highly verbose and difficult to remember, even after a decade of writing it:

```sql
select *, 
    sum(revenue) over (
        partition by date order by timestamp rows between unbounded preceding and current row
    ) as window_function
from table
qualify window_function < 1000
```

As of this moment, I do not have a proposed alternate syntax. I am simply documenting this
as a pain point I would like to redesign.

# Build Instructions

-`zig build` to build

-`./zig-out/bin/dbconnect` to run
