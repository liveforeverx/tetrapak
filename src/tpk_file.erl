
%    __                        __      _
%   / /__________ __   _____  / /___  (_)___  ____ _
%  / __/ ___/ __ `/ | / / _ \/ / __ \/ / __ \/ __ `/
% / /_/ /  / /_/ /| |/ /  __/ / /_/ / / / / / /_/ /
% \__/_/   \__,_/ |___/\___/_/ .___/_/_/ /_/\__, /
%                           /_/            /____/
%
% Copyright (c) Travelping GmbH <info@travelping.com>

-module(tpk_file).
-export([size/1, mtime/1, md5sum/1, is_useless/1, filter_useless/1, basename/1, rebase_filename/3]).
-export([temp_name/0, temp_name/1, mkdir/1, with_temp_dir/1,
         dir_contents/1, dir_contents/2, dir_contents/3,
         wildcard/2]).
-export([copy/2, delete/1, delete/2, walk/3, walk/4]).
-export([make_tarball/4, make_tarball_from_files/4, varsubst/3]).

-include_lib("kernel/include/file.hrl").

basename(Filename) ->
    Abs = filename:absname(Filename),
    case filename:basename(Abs) of
        "." -> filename:dirname(Abs);
        Other -> Other
    end.

size(Filename) ->
    {ok, #file_info{size = Size}} = file:read_file_info(Filename),
    Size.

mtime(Filename) ->
    {ok, #file_info{mtime = MTime}} = file:read_file_info(Filename),
    MTime.

rebase_filename(FName, FromDir, ToDir) ->
    FromDirPath = filename:split(FromDir),
    FPath = filename:split(FName),
    case lists:prefix(FromDirPath, FPath) of
        true ->
            RP = FPath -- FromDirPath,
            Joined = filename:join([ToDir|RP]),
            case ToDir of
                "" -> tl(Joined);
                _  -> Joined
            end;
        false ->
            exit(bad_filename)
    end.

is_useless(Filename) ->
    Name = basename(Filename),
    tpk_util:match(".*~$", Name) or tpk_util:match("^\\..*", Name) or tpk_util:match("^.*/\\.git/.*$", Filename).

filter_useless(Files) ->
    lists:filter(fun (X) -> not is_useless(X) end, Files).

temp_name() -> temp_name("/tmp").
temp_name(Dir) ->
    {A,B,C} = now(),
    Pid = re:replace(erlang:pid_to_list(self()), "<|>", "", [global, {return, list}]),
    filename:join(Dir, tpk_util:f("tetrapak-tmp-~p-~p-~p-~s", [A,B,C,Pid])).

with_temp_dir(DoSomething) ->
    Temp = temp_name(),
    file:make_dir(Temp),
    try DoSomething(Temp)
    after
        tpk_log:debug("deleting directory ~s", [Temp]),
        delete(Temp)
    end.

dir_contents(Dir) -> dir_contents(Dir, ".*").
dir_contents(Dir, Mask) -> dir_contents(Dir, Mask, no_dir).
dir_contents(Dir, Mask, DirOpt) ->
    AddL = fun (F, Acc) ->
                   case tpk_util:match(Mask, F) of
                       true -> [F|Acc];
                       false -> Acc
                   end
           end,
    case filelib:is_dir(Dir) of
        true -> lists:reverse(walk(AddL, [], Dir, DirOpt));
        false -> []
    end.

wildcard(Dir, Wildcard) ->
    WC = filename:join(filename:absname(Dir), Wildcard),
    filelib:wildcard(WC).

mkdir(Path) ->
    filelib:ensure_dir(filename:join(Path, ".")).

copy(From, To) ->
    CP = fun (F, _) ->
                case not is_useless(F) of
                    true ->
                        T = rebase_filename(F, From, To),
                        ok = filelib:ensure_dir(T),
                        case file:copy(F, T) of
                            {ok, _} ->
                                {ok, #file_info{mode = Mode}} = file:read_file_info(F),
                                file:change_mode(T, Mode);
                            {error, Reason} -> throw({file_copy_error, Reason})
                        end;
                    false -> nomatch
                end
        end,
    walk(CP, [], From, no_dir).

delete(Filename) ->
    delete(".*", Filename).
delete(Mask, Filename) ->
    walk(fun (F, _) -> delete_if_match(Mask, F) end, [], Filename, dir_last).

delete_if_match(Mask, Path) ->
    case tpk_util:match(Mask, filename:basename(Path)) of
        true ->
            case filelib:is_dir(Path) of
                true  ->
                    tpk_log:debug("rmdir ~s", [Path]),
                    file:del_dir(Path);
                false ->
                    tpk_log:debug("rm ~s", [Path]),
                    file:delete(Path)
            end;
        false -> ok
    end.

walk(Fun, AccIn, Path) -> walk(Fun, AccIn, Path, no_dir).
walk(Fun, AccIn, Path, DirOpt) when (DirOpt == no_dir) or
                                    (DirOpt == dir_first) or
                                    (DirOpt == dir_last) ->
    walk(Fun, {walk, Path}, AccIn, [], DirOpt).
walk(Fun, {Walk, Path}, Acc, Queue, DirOpt) ->
    case {Walk, filelib:is_dir(Path)} of
        {walk, true} ->
            {ok, List} = file:list_dir(Path),
            AddPaths = lists:map(fun (Name) -> {walk, filename:join(Path, Name)} end, List),
            [Next|Rest] = case DirOpt of
                              no_dir -> AddPaths ++ Queue;
                              dir_first -> [{nowalk, Path}|AddPaths] ++ Queue;
                              dir_last -> AddPaths ++ [{nowalk, Path}|Queue]
                          end,
            walk(Fun, Next, Acc, Rest, DirOpt);
        {_, _} ->
            case Queue of
                [] -> Fun(Path,Acc);
                [Next|Rest] -> walk(Fun, Next, Fun(Path, Acc), Rest, DirOpt)
            end
    end.

make_tarball(Outfile, Root, Dir, Mask) ->
    Files = dir_contents(Dir, Mask, dir_first),
    make_tarball_from_files(Outfile, Root, Dir, Files).

make_tarball_from_files(Outfile, Root, Dir, Files) ->
    XFEsc = fun (P) -> re:replace(P, "([,])", "\\\\\\1", [global, {return, list}]) end,
    XForm = tpk_util:f("s,~s,~s,", [XFEsc(filename:absname(Dir)), XFEsc(Root)]),
    tpk_util:run("tar", ["--create", "--directory", Dir, "--file", Outfile, "--format=ustar",
                         "--numeric-owner", "--owner=root", "--group=root", "--gzip",
                         "--no-recursion", "--touch", "--absolute-names",
                         "--preserve-permissions", "--preserve-order",
                         "--transform", XForm | lists:map(fun filename:absname/1, Files)]).

varsubst(Variables, Infile, Outfile) ->
    tpk_log:debug("varsubst: ~s -> ~s", [Infile, Outfile]),
    {ok, Content} = file:read_file(Infile),
    NewContent = tpk_util:varsubst(Content, Variables),
    tpk_log:debug("~p", [NewContent]),
    file:write_file(Outfile, NewContent).

md5sum(File) ->
    case file:open(File, [binary,raw,read]) of
        {ok, P} ->
            Digest = md5_loop(P, erlang:md5_init()),
            bin_to_hex(binary_to_list(Digest));
        Error   -> Error
    end.

md5_loop(P, C) ->
    case file:read(P, 150) of
        {ok, Bin} ->
            md5_loop(P, erlang:md5_update(C, Bin));
        eof ->
            file:close(P),
            erlang:md5_final(C)
    end.

bin_to_hex([H|T]) ->
    H1 = nibble2hex(H bsr 4),
    H2 = nibble2hex(H band 15),
    [H1, H2 | bin_to_hex(T)];
bin_to_hex([]) ->
    [].

nibble2hex(X) when X < 10 -> X + $0;
nibble2hex(X)             -> X - 10 + $a.