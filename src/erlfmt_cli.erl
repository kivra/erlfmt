%% Copyright (c) Meta Platforms, Inc. and its affiliates.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
-module(erlfmt_cli).

-export([opts/0, do/2, do/3]).

-type out() :: standard_out | {path, file:name_all()} | replace | check.

-record(config, {
    verbose = false :: boolean(),
    pretty_print = undefined :: undefined | plain | github,
    print_width = undefined :: undefined | pos_integer(),
    pragma = ignore :: erlfmt:pragma(),
    out = standard_out :: out(),
    range = undefined :: undefined | {pos_integer(), pos_integer()}
}).

-type parsed() :: {format, list(), list(), #config{}} | help | version | {error, string()}.

opts() ->
    [
        {help, $h, "help", undefined, "print this message"},
        {version, $v, "version", undefined, "print version"},
        {write, $w, "write", undefined, "modify formatted files in place"},
        {out, $o, "out", binary, "output directory"},
        {verbose, undefined, "verbose", undefined, "include debug output"},
        {check, $c, "check", undefined,
            "Check if your files are formatted. "
            "Get exit code 1, if some files are not formatted. "
            "--write is not supported."},
        {pretty_print, undefined, "pretty-print", string,
            "Format to print result as (plain | github)"}, 
        {print_width, undefined, "print-width", integer,
            "The line length that formatter would wrap on"},
        {require_pragma, undefined, "require-pragma", undefined,
            "Require a special comment @format, called a pragma, "
            "to be present in the file's first docblock comment in order for erlfmt to format it."},
        {insert_pragma, $i, "insert-pragma", undefined,
            "Insert a @format pragma to the top of formatted files when pragma is absent. "
            "Works well when used in tandem with --require-pragma, "
            "but it is not allowed to use require-pragma and insert-pragma at the same time."},
        {delete_pragma, undefined, "delete-pragma", undefined,
            "Deletes the @format pragma at the top of formatted files. "
            "It will also reformat the file, but is only applied to files with a pragma, see --require-pragma."},
        % The getopt module doesn't support tuple of integers as a type,
        % So we accept a string, and do an ad-hoc parsing manually.
        {range, undefined, "range", string,
            "Range to be formatted in start-end format (both inclusive). "
            "Warning! A bigger range might end up being formatted, as for now the format granularity is top-level form."},
        {exclude_files, undefined, "exclude-files", string,
            "files not to format. "
            "This overrides the files specified to format"},
        {files, undefined, undefined, string,
            "files to format, - for stdin. "
            "If no files are provided and one option of [-w, -o, -c] are provided then "
            "{src,include,test}/*.{hrl,erl,app.src} and rebar.config "
            "are specified as the default."}
    ].

-spec do(string(), list()) -> ok.
do(Name, Opts) ->
    do(Name, Opts, []).

-spec do(string(), list(), list()) -> ok.
do(Name, PreferOpts, DefaultOpts) ->
    PreferParsed = parse_opts(PreferOpts),
    DefaultParsed = parse_opts(DefaultOpts),
    SpecifiedFiles = specified_files(PreferOpts) ++ specified_files(DefaultOpts),
    Parsed =
        case {PreferParsed, DefaultParsed, SpecifiedFiles} of
            {
                {format, _, _, #config{out = standard_out}},
                {format, _, _, #config{out = standard_out}},
                _
            } ->
                %% Do not provide default files if we are writing to stdout
                resolve_parsed(PreferParsed, DefaultParsed);
            {{format, [], _, _}, {format, [], _, _}, _} when SpecifiedFiles =/= [] ->
                io:format(standard_error, "no files matching ~p~n", [SpecifiedFiles]),
                help;
            {_, _, []} ->
                %% no files means we should provide default files
                DefaultFiles = parse_opts([
                    {files, ["{src,include,test}/*.{hrl,erl,app.src}", "rebar.config"]}
                ]),
                resolve_parsed(PreferParsed, resolve_parsed(DefaultParsed, DefaultFiles));
            _ ->
                resolve_parsed(PreferParsed, DefaultParsed)
        end,
    with_parsed(Name, Parsed).

-spec with_parsed(string(), parsed()) -> ok.
with_parsed(Name, Config) ->
    try
        unprotected_with_config(Name, Config)
    catch
        Kind:Reason:Stack ->
            io:format(standard_error, "~s Internal Error~n~s:~p~n~p~n", [Name, Kind, Reason, Stack]),
            erlang:halt(127)
    end.

set_difference(Files, Excludes) ->
    sets:to_list(sets:subtract(sets:from_list(Files), sets:from_list(Excludes))).

%% needed because of getopt
-dialyzer({nowarn_function, [unprotected_with_config/2]}).

-spec unprotected_with_config(string(), parsed()) -> ok.
unprotected_with_config(Name, ParsedConfig) ->
    case ParsedConfig of
        {format, Files0, Excludes, Config} ->
            Pretty = set_pretty_printing(Config),
            case set_difference(Files0, Excludes) of
                [] ->
                    io:put_chars(standard_error, ["no files provided to format\n\n"]),
                    getopt:usage(opts(), Name),
                    erlang:halt(2);
                Files ->
                    case Config#config.out of
                        check -> io:format(standard_error, "Checking formatting...~n", []);
                        _ -> ok
                    end,
                    FormatFileFun = fun(File) ->
                        set_pretty_printing(Pretty),
                        format_file(File, Config)
                    end,
                    case parallel(FormatFileFun, Files) of
                        ok ->
                            case Config#config.out of
                                check ->
                                    io:format(
                                        standard_error,
                                        "All matched files use erlfmt code style!~n",
                                        []
                                    );
                                _ ->
                                    ok
                            end;
                        warn ->
                            io:format(
                                standard_error,
                                "[warn] Code style issues found in the above file(s). Forgot to run erlfmt?~n",
                                []
                            ),
                            erlang:halt(1);
                        error ->
                            erlang:halt(4)
                    end
            end;
        {error, Message} ->
            io:put_chars(standard_error, [Message, "\n\n"]),
            getopt:usage(opts(), Name),
            erlang:halt(2);
        help ->
            getopt:usage(opts(), Name),
            erlang:halt(0);
        version ->
            {ok, Vsn} = application:get_key(erlfmt, vsn),
            io:format("~s version ~s\n", [Name, Vsn]),
            erlang:halt(0)
    end.

set_pretty_printing(#config{pretty_print = Pretty}) ->
    set_pretty_printing(Pretty);
set_pretty_printing(P) when P == plain; P == github ->
    erlang:put(pretty_print, P),
    P;
set_pretty_printing(undefined) ->
    case string:casefold(os:getenv("GITHUB_ACTIONS", "false")) of
        "true" ->
            set_pretty_printing(github);
        "false" ->
            set_pretty_printing(plain)
    end.

format_file(FileName, Config) ->
    #config{pragma = Pragma, print_width = PrintWidth, verbose = Verbose, out = Out, range = Range} =
        Config,
    case Verbose of
        true -> io:format(standard_error, "Formatting ~s\n", [FileName]);
        false -> ok
    end,
    Options =
        [{pragma, Pragma}] ++
            [{print_width, PrintWidth} || PrintWidth =/= undefined] ++
            [verbose || Verbose] ++
            [{range, Range} || Range =/= undefined],
    Result =
        case {Range, Out, FileName} of
            {undefined, check, stdin} ->
                check_stdin(Options);
            {undefined, check, _} ->
                check_file(FileName, Options);
            {{_, _}, check, _} ->
                {error, "Checking of range not supported."};
            {{_, _}, replace, _} ->
                {error, "In place formatting of range not supported yet."};
            _ ->
                erlfmt:format_file(FileName, Options)
        end,
    case {Verbose, Result} of
        {true, {skip, _}} ->
            io:format(standard_error, "Skipping ~s because of missing @format pragma\n", [FileName]);
        _ ->
            ok
    end,
    case Result of
        {ok, FormattedText, Warnings} ->
            [print_error_info(Warning) || Warning <- Warnings],
            write_formatted(FileName, FormattedText, Out);
        {warn, Warnings} ->
            [print_error_info(Warning) || Warning <- Warnings],
            print_filename_warning(FileName),
            warn;
        {skip, RawString} ->
            write_formatted(FileName, RawString, Out);
        {error, Error} ->
            print_error_info(Error),
            error
    end.

print_filename_warning(FileName) ->
    print_filename_warning(erlang:get(pretty_print), FileName).

print_filename_warning(github, FileName) ->
    io:format(standard_error, "::notice file=~s::File ~s has warnings~n", [FileName, FileName]);
print_filename_warning(_, FileName) ->
    io:format(standard_error, "[warn] ~s\n", [FileName]).

write_formatted(_FileName, _Formatted, check) ->
    ok;
write_formatted(_FileName, Formatted, standard_out) ->
    io:put_chars(Formatted);
write_formatted(FileName, Formatted, Out) ->
    OutFileName = out_file(FileName, Out),
    case filelib:ensure_dir(OutFileName) of
        ok ->
            ok;
        {error, Reason1} ->
            print_error_info({OutFileName, 0, file, Reason1}),
            error
    end,
    {ok, OriginalBin} = file:read_file(FileName),
    case unicode:characters_to_binary(Formatted) of
        OriginalBin -> ok;
        FormattedBin -> write_file(OutFileName, FormattedBin)
    end.

write_file(OutFileName, FormattedBin) ->
    case file:write_file(OutFileName, unicode:characters_to_binary(FormattedBin)) of
        ok ->
            ok;
        {error, Reason2} ->
            print_error_info({OutFileName, 0, file, Reason2}),
            error
    end.

out_file(FileName, replace) ->
    FileName;
out_file(FileName, {path, Path}) ->
    filename:join(Path, filename:basename(FileName)).

check_file(FileName, Options) ->
    case erlfmt:format_file(FileName, Options) of
        {ok, Formatted, FormatWarnings} ->
            {ok, OriginalBin} = file:read_file(FileName),
            FormattedBin = unicode:characters_to_binary(Formatted),
            case FormattedBin of
                OriginalBin -> {ok, Formatted, FormatWarnings};
                _ -> {warn, FormatWarnings}
            end;
        Other ->
            Other
    end.

check_stdin(Options) ->
    CurrentOpts = io:getopts(standard_io),
    io:setopts(standard_io, [binary, {encoding, unicode}]),
    Result =
        case read_stdin([]) of
            {ok, OriginalBin} ->
                Original = unicode:characters_to_list(OriginalBin),
                case erlfmt:format_string(Original, Options) of
                    {ok, Formatted, FormatWarnings} ->
                        case Formatted of
                            Original -> {ok, Formatted, FormatWarnings};
                            _ -> {warn, FormatWarnings}
                        end;
                    Other ->
                        Other
                end;
            {error, Reason} ->
                {error, Reason}
        end,
    io:setopts(standard_io, CurrentOpts),
    Result.

-dialyzer({no_improper_lists, [read_stdin/1]}).

read_stdin(Data) ->
    case io:get_chars(standard_io, "", 4096) of
        MoreData when is_binary(MoreData) -> read_stdin([Data | MoreData]);
        eof -> {ok, Data};
        {error, Reason} -> {error, Reason}
    end.

-spec parse_opts(list()) -> parsed().
parse_opts(Args) ->
    parse_opts(Args, [], [], #config{}).

parse_opts([help | _Rest], _Files, _Exclude, _Config) ->
    help;
parse_opts([version | _Rest], _Files, _Exclude, _Config) ->
    version;
parse_opts([write | _Rest], _Files, _Exclude, #config{out = Out}) when Out =/= standard_out ->
    {error, "--write or replace mode can't be combined check mode"};
parse_opts([write | Rest], Files, Exclude, Config) ->
    parse_opts(Rest, Files, Exclude, Config#config{out = replace});
parse_opts([{out, _Path} | _Rest], _Files, _Exclude, #config{out = Out}) when
    Out =/= standard_out
->
    {error, "out or replace mode can't be combined check mode"};
parse_opts([{out, Path} | Rest], Files, Exclude, Config) ->
    parse_opts(Rest, Files, Exclude, Config#config{out = {path, Path}});
parse_opts([verbose | Rest], Files, Exclude, Config) ->
    parse_opts(Rest, Files, Exclude, Config#config{verbose = true});
parse_opts([check | _Rest], _Files, _Exclude, #config{out = Out}) when Out =/= standard_out ->
    {error, "--check mode can't be combined write or replace mode"};
parse_opts([check | Rest], Files, Exclude, Config) ->
    parse_opts(Rest, Files, Exclude, Config#config{out = check});
parse_opts([{pretty_print, Value} | Rest], Files, Exclude, Config) ->
    case
        case string:casefold(Value) of
            "github" -> github;
            "plain" -> plain;
            Other -> {error, Other}
        end
    of
        {error, Unsupported} ->
            {error, ["Unsupported pretty printing: ", Unsupported]};
        Pretty when is_atom(Pretty) ->
            parse_opts(Rest, Files, Exclude, Config#config{pretty_print = Pretty})
    end;
parse_opts([{print_width, Value} | Rest], Files, Exclude, Config) ->
    parse_opts(Rest, Files, Exclude, Config#config{print_width = Value});
parse_opts([require_pragma | _Rest], _Files, _Exclude, #config{pragma = insert}) ->
    {error, "Cannot use both --insert-pragma and --require-pragma options together."};
parse_opts([require_pragma | _Rest], _Files, _Exclude, #config{pragma = delete}) ->
    {error, "Cannot use both --delete-pragma and --require-pragma options together."};
parse_opts([require_pragma | Rest], Files, Exclude, Config) ->
    parse_opts(Rest, Files, Exclude, Config#config{pragma = require});
parse_opts([insert_pragma | _Rest], _Files, _Exclude, #config{pragma = require}) ->
    {error, "Cannot use both --insert-pragma and --require-pragma options together."};
parse_opts([insert_pragma | _Rest], _Files, _Exclude, #config{pragma = delete}) ->
    {error, "Cannot use both --insert-pragma and --delete-pragma options together."};
parse_opts([insert_pragma | Rest], Files, Exclude, Config) ->
    parse_opts(Rest, Files, Exclude, Config#config{pragma = insert});
parse_opts([delete_pragma | _Rest], _Files, _Exclude, #config{pragma = insert}) ->
    {error, "Cannot use both --insert-pragma and --delete-pragma options together."};
parse_opts([delete_pragma | _Rest], _Files, _Exclude, #config{pragma = require}) ->
    {error, "Cannot use both --require-pragma and --delete-pragma options together."};
parse_opts([delete_pragma | Rest], Files, Exclude, Config) ->
    parse_opts(Rest, Files, Exclude, Config#config{pragma = delete});
parse_opts([{range, String} | Rest], Files, Exclude, Config) ->
    % Ad-hoc parsing. Mitigation for the absence of "couple of integers" direct support.
    Range1 = string:split(String, ",", all),
    Range2 = [list_to_integer(X) || X <- Range1],
    Range3 =
        case Range2 of
            [X] ->
                % Single line. Set end=start
                [X, X];
            [X, Y] ->
                [X, Y];
            _ ->
                {error, "Range: Expected 1 argument (single line) or 2 (start, end)."}
        end,
    case Range3 of
        [Start, End] when Start > End ->
            {error, "Range: End must be greater or equal than Start."};
        [Start, End] ->
            parse_opts(Rest, Files, Exclude, Config#config{range = {Start, End}});
        Error ->
            Error
    end;
parse_opts([{files, NewFiles} | Rest], Files, Exclude, Config) ->
    parse_opts(Rest, expand_files(NewFiles, Files), Exclude, Config);
parse_opts([{exclude_files, NewExcludes} | Rest], Files, Exclude, Config) ->
    parse_opts(Rest, Files, expand_files(NewExcludes, Exclude), Config);
parse_opts([], [stdin], _Exclude, #config{out = Out}) when Out =/= standard_out, Out =/= check ->
    {error, "stdin mode can't be combined with write options"};
parse_opts([], [stdin], [], Config) ->
    {format, [stdin], [], Config};
parse_opts([], [stdin], [_Exclude | _], _Config) ->
    {error, "stdin mode can't be combined with excluded files"};
parse_opts([], Files, Exclude, Config) ->
    case lists:member(stdin, Files) of
        true -> {error, "stdin mode can't be combined with other files"};
        false -> {format, lists:reverse(Files), lists:reverse(Exclude), Config}
    end;
parse_opts([Unknown | _], _Files, _Exclude, _Config) ->
    {error, io_lib:format("unknown option: ~p", [Unknown])}.

-spec resolve_parsed(parsed(), parsed()) -> parsed().
resolve_parsed(PreferParsed, DefaultParsed) ->
    case {PreferParsed, DefaultParsed} of
        {{error, _} = Error, _} ->
            Error;
        {_, {error, _} = Error} ->
            Error;
        {help, _} ->
            help;
        {_, help} ->
            help;
        {version, _} ->
            version;
        {_, version} ->
            version;
        {
            {format, PreferFiles, PreferExclude, PreferConfig},
            {format, DefaultFiles, DefaultExclude, DefaultConfig}
        } ->
            {format, resolve_files(PreferFiles, DefaultFiles),
                resolve_files(PreferExclude, DefaultExclude),
                resolve_config(PreferConfig, DefaultConfig)}
    end.

resolve_files([], DefaultFiles) -> DefaultFiles;
resolve_files(PreferFiles, _DefaultFiles) -> PreferFiles.

resolve_config(
    #config{
        verbose = PreferVerbose,
        pretty_print = PreferPretty,
        print_width = PreferWidth,
        pragma = PreferPragma,
        out = PreferOut,
        range = PreferRange
    },
    #config{
        verbose = DefaultVerbose,
        pretty_print = DefaultPretty,
        print_width = DefaultWidth,
        pragma = DefaultPragma,
        out = DefaultOut,
        range = DefaultRange
    }
) ->
    #config{
        verbose = PreferVerbose orelse DefaultVerbose,
        pretty_print = resolve_pretty(PreferPretty, DefaultPretty),
        print_width = resolve_width(PreferWidth, DefaultWidth),
        pragma = resolve_pragma(PreferPragma, DefaultPragma),
        out = resolve_out(PreferOut, DefaultOut),
        range = resolve_range(PreferRange, DefaultRange)
    }.

resolve_pretty(undefined, P) -> P;
resolve_pretty(P, _) -> P.

resolve_width(undefined, W) -> W;
resolve_width(W, _) -> W.

resolve_pragma(ignore, P) -> P;
resolve_pragma(P, _) -> P.

resolve_out(standard_out, O) -> O;
resolve_out(O, _) -> O.

resolve_range(undefined, R) -> R;
resolve_range(R, _) -> R.

specified_files(List) ->
    lists:filter(
        fun
            ({files, _}) -> true;
            (stdin) -> true;
            (_) -> false
        end,
        List
    ).

expand_files("-", Files) ->
    [stdin | Files];
expand_files(NewFile, Files) when is_integer(hd(NewFile)) ->
    case filelib:is_regular(NewFile) of
        true ->
            [NewFile | Files];
        false ->
            case filelib:wildcard(NewFile) of
                [] ->
                    Files;
                NewFiles ->
                    NewFiles ++ Files
            end
    end;
expand_files(NewFiles, Files) when is_list(NewFiles) ->
    lists:foldl(fun expand_files/2, Files, NewFiles).

print_error_info(Info) ->
    Pretty = erlang:get(pretty_print),
    print_error_info(Pretty, Info).

print_error_info(github, {File, Line, _, _}=Info) ->
    io:format(standard_error, "::warning file=~s,line=~b::~s~n", [File, Line, erlfmt:format_error_info(Info)]);
print_error_info(github, Info) ->
    io:format("~p", [Info]),
    io:put_chars(standard_error, [ erlfmt:format_error_info(Info), $\n]);
print_error_info(_, Info) ->
    io:put_chars(standard_error, [erlfmt:format_error_info(Info), $\n]).

parallel(Fun, List) ->
    N = erlang:system_info(schedulers) * 2,
    parallel_loop(Fun, List, N, [], _ReducedResult = ok).

parallel_loop(_, [], _, [], ReducedResult) ->
    ReducedResult;
parallel_loop(Fun, [Elem | Rest], N, Refs, ReducedResult) when length(Refs) < N ->
    {_, Ref} = erlang:spawn_monitor(fun() -> exit(Fun(Elem)) end),
    parallel_loop(Fun, Rest, N, [Ref | Refs], ReducedResult);
parallel_loop(Fun, List, N, Refs0, ReducedResult0) ->
    receive
        {'DOWN', Ref, process, _, Result} when
            Result =:= error; Result =:= warn; Result =:= ok; Result =:= skip
        ->
            Refs = Refs0 -- [Ref],
            ReducedResult =
                case {Result, ReducedResult0} of
                    {_, error} -> error;
                    {error, _} -> error;
                    {_, warn} -> warn;
                    {warn, _} -> warn;
                    {_, _} -> ok
                end,
            parallel_loop(Fun, List, N, Refs, ReducedResult);
        {'DOWN', _Ref, process, _, Crash} ->
            exit(Crash)
    end.
