using Graphs

export In, Out, InOut, Deps, spawn_datadeps

"Specifies a read-only dependency."
struct In{T}
    x::T
end
"Specifies a write-only dependency."
struct Out{T}
    x::T
end
"Specifies a read-write dependency."
struct InOut{T}
    x::T
end
"Specifies one or more dependencies."
struct Deps{T,DT<:Tuple}
    x::T
    deps::DT
end
Deps(x, deps...) = Deps(x, deps)

struct DataDepsTaskQueue <: AbstractTaskQueue
    # The queue above us
    upper_queue::AbstractTaskQueue
    # The mapping of unique objects to previously-launched tasks,
    # and their data dependency on the object (read, write)
    deps::IdDict{Any, Vector{Pair{Tuple{Bool,Bool}, EagerThunk}}}

    # Whether to analyze the DAG statically or eagerly
    # The fields following only apply when static==true
    static::Bool
    # The set of tasks that have already been seen
    seen_tasks::Union{Vector{Pair{EagerTaskSpec,EagerThunk}},Nothing}
    # The data-dependency graph of all tasks
    g::Union{SimpleDiGraph{Int},Nothing}
    # The mapping from task to graph ID
    task_to_id::Union{Dict{EagerThunk,Int},Nothing}
    # How to traverse the dependency graph when launching tasks
    traversal::Symbol

    # Whether aliasing across arguments is possible
    # The fields following only apply when aliasing==true
    aliasing::Bool
    # The mapping from arguments to their memory spans
    arg_to_spans::IdDict{Any,Vector{MemorySpan}}
    # The ordered list of tasks and their read/write dependencies
    dependencies::Vector{Pair{EagerThunk,Vector{Tuple{Bool,Bool,Vector{MemorySpan}}}}}

    function DataDepsTaskQueue(upper_queue; static::Bool=true,
                               traversal::Symbol=:inorder, aliasing::Bool=true)
        deps = IdDict{Any, Vector{Pair{Tuple{Bool,Bool}, EagerThunk}}}()
        if static
            seen_tasks = Pair{EagerTaskSpec,EagerThunk}[]
            g = SimpleDiGraph()
            task_to_id = Dict{EagerThunk,Int}()
            arg_to_spans = IdDict{Any,Vector{MemorySpan}}()
            dependencies = Pair{EagerThunk,Vector{Tuple{Bool,Bool,Vector{MemorySpan}}}}[]
        else
            seen_tasks = nothing
            g = nothing
            task_to_id = nothing
            arg_to_spans = nothing
            dependencies = nothing
        end
        return new(upper_queue, deps,
                   static, seen_tasks, g, task_to_id, traversal,
                   aliasing, arg_to_spans, dependencies)
    end
end

function _enqueue!(queue::DataDepsTaskQueue, fullspec::Pair{EagerTaskSpec,EagerThunk})
    # If static, record this task and its edges in the graph
    if queue.static
        g = queue.g
        task_to_id = queue.task_to_id
    end

    spec, task = fullspec
    if queue.static
        add_vertex!(g)
        task_to_id[task] = our_task_id = nv(g)
    else
        opts = spec.options
        syncdeps = get(Set{Any}, opts, :syncdeps)
        scope = get(DefaultScope, opts, :scope)
        worker_scope = ProcessScope(myid())
        new_scope = constrain(scope, worker_scope)
        if new_scope isa InvalidScope
            throw(SchedulingException("Scopes are not compatible: $scope vs $worker_scope"))
        end
        scope = new_scope
    end

    deps_to_add = Vector{Pair{Any, Tuple{Bool,Bool}}}()
    if queue.aliasing
        dependencies_to_add = Vector{Tuple{Bool,Bool,Vector{MemorySpan}}}()
    end

    function unwrap_inout(arg)
        readdep = false
        writedep = false
        if arg isa In
            readdep = true
            arg = arg.x
        elseif arg isa Out
            writedep = true
            arg = arg.x
        elseif arg isa InOut
            readdep = true
            writedep = true
            arg = arg.x
        else
            readdep = true
        end
        return arg, (readdep, writedep)
    end
    # Track the task's arguments and access patterns
    for (idx, (pos, arg)) in enumerate(spec.args)
        # Unwrap In/InOut/Out wrappers and record dependencies
        alldeps = nothing
        if arg isa Deps
            # Conservative readdep/writedep status in case aliasing is disabled
            readdep = any(dep->dep isa Union{In,InOut}, arg.deps)
            writedep = any(dep->dep isa Union{Out,InOut}, arg.deps)
            alldeps = arg.deps
            #arg = arg.x
        else
            arg, (readdep, writedep) = unwrap_inout(arg)
        end
        spec.args[idx] = pos => arg

        # Unwrap the Chunk underlying any EagerThunk arguments
        arg_is_launched_task = arg isa EagerThunk && istaskstarted(arg)
        arg_is_unlaunched_task = arg isa EagerThunk && !istaskstarted(arg)
        arg_data = arg_is_launched_task ? fetch(arg; raw=true) : arg

        push!(deps_to_add, arg_data => (readdep, writedep))
        if queue.aliasing && !arg_is_unlaunched_task
            if alldeps !== nothing
                for dep in alldeps
                    dep_mod, (readdep, writedep) = unwrap_inout(dep)
                    push!(dependencies_to_add, (readdep, writedep, memory_spans(arg_data.x, dep_mod)))
                end
            else
                push!(dependencies_to_add, (readdep, writedep, memory_spans(arg_data)))
            end
        end

        # FIXME: This is wrong for the dynamic scheduler, and for static graph building
        if !haskey(queue.deps, arg_data)
            continue
        end
        argdeps = queue.deps[arg_data]::Vector{Pair{Tuple{Bool,Bool}, EagerThunk}}
        if readdep
            # When you have an in dependency, sync with the previous out
            for ((other_readdep::Bool, other_writedep::Bool),
                 other_task::EagerThunk) in argdeps
                if other_writedep
                    if queue.static
                        other_task_id = task_to_id[other_task]
                        add_edge!(g, other_task_id, our_task_id)
                    else
                        push!(syncdeps, other_task)
                    end
                end
            end
        end
        if writedep
            # When you have an out dependency, sync with the previous in or out
            for ((other_readdep::Bool, other_writedep::Bool),
                other_task::EagerThunk) in argdeps
                if other_readdep || other_writedep
                    if queue.static
                        other_task_id = task_to_id[other_task]
                        add_edge!(g, other_task_id, our_task_id)
                    else
                        push!(syncdeps, other_task)
                    end
                end
           end
        end
    end

    # Track the task result too
    push!(deps_to_add, task => (true, true))
    @warn "Push to dependencies_to_add, by not recording memory spans here" maxlog=1

    # Record argument/result dependencies
    for (arg_data, (readdep, writedep)) in deps_to_add
        # Record read/write dependencies per value
        argdeps = get!(queue.deps, arg_data) do
            Vector{Pair{Tuple{Bool,Bool}, EagerThunk}}()
        end
        push!(argdeps, (readdep, writedep) => task)
        if queue.aliasing
            push!(queue.dependencies, task => dependencies_to_add)
        end
    end

    if !queue.static
        spec.options = merge(opts, (;syncdeps, scope))
    end
end
function enqueue!(queue::DataDepsTaskQueue, spec::Pair{EagerTaskSpec,EagerThunk})
    _enqueue!(queue, spec)
    if queue.static
        push!(queue.seen_tasks, spec)
    else
        enqueue!(queue.upper_queue, spec)
    end
end
function enqueue!(queue::DataDepsTaskQueue, specs::Vector{Pair{EagerTaskSpec,EagerThunk}})
    for spec in specs
        _enqueue!(queue, spec)
    end
    if queue.static
        append!(queue.seen_tasks, specs)
    else
        enqueue!(queue.upper_queue, specs)
    end
end

function distribute_tasks!(queue::DataDepsTaskQueue)
    #= TODO: Improvements to be made:
    # - Support for non-CPU processors
    # - Support for copying non-AbstractArray arguments
    # - Use graph coloring for scheduling OR use Dagger's scheduler directly
    # - Generate slots on-the-fly
    # - Parallelize read copies
    # - Unreference unused slots
    # - Reuse memory when possible (SafeTensors)
    # - Account for differently-sized data
    # - Account for different task execution times
    =#

    # Determine which arguments could be written to, and thus need tracking
    if queue.aliasing
        arg_to_spans = queue.arg_to_spans
        span_has_writedep = IdDict{MemorySpan,Bool}()
    else
        arg_has_writedep = IdDict{Any,Bool}()
    end
    function populate_writedeps!(arg, deps=nothing)
        haskey(queue.deps, arg) || return
        if queue.aliasing
            haskey(arg_to_spans, arg) && return
            if deps !== nothing
                spans = MemorySpan[]
                for dep in arg.deps
                    dep_mod, _ = unwrap_inout(dep)
                    append!(spans, memory_spans(arg.x, dep_mod))
                end
            else
                spans = arg_to_spans[arg] = memory_spans(arg)
            end
            for span in spans
                writedep = false
                for (_, taskdeps) in queue.dependencies
                    for (_, span_writedep, other_spans) in taskdeps
                        span_writedep || continue
                        if any(will_alias(span, other_span) for other_span in other_spans)
                            writedep = true
                            break
                        end
                    end
                    writedep && break
                end
                span_has_writedep[span] = writedep
            end
        else
            haskey(arg_has_writedep, arg) && return
            writedep = any(argdep->argdep[1][2], queue.deps[arg])
            arg_has_writedep[arg] = writedep
        end
    end
    for (arg, argdeps) in queue.deps
        arg isa EagerThunk && !istaskstarted(arg) && continue
        populate_writedeps!(arg)
    end
    "Whether `arg` has any writedep in this datadeps region."
    function has_writedep(arg)
        haskey(queue.deps, arg) || return false
        if queue.aliasing
            return any(span->span_has_writedep[span], arg_to_spans[arg])
        else
            return arg_has_writedep[arg]
        end
    end
    """
    Whether `arg` has any writedep at or before executing `task` in this
    datadeps region.
    """
    function has_writedep(arg, task::EagerThunk)
        haskey(queue.deps, arg) || return false
        any_writedep = false
        if queue.aliasing
            for (other_task, other_taskdeps) in queue.dependencies
                for (readdep, writedep, other_spans) in other_taskdeps
                    writedep || continue
                    any(will_alias(span, other_span) for span in arg_to_spans[arg], other_span in other_spans) || continue
                    any_writedep = true
                    break
                end
                if task === other_task
                    return any_writedep
                end
            end
        else
            for ((readdep, writedep), other_task) in queue.deps[arg]
                any_writedep |= writedep
                if task === other_task
                    return any_writedep
                end
            end
        end
        error("Task isn't in argdeps set")
    end
    "Whether `arg` is written to by `task`."
    function is_writedep(arg, task::EagerThunk)
        haskey(queue.deps, arg) || return false
        if queue.aliasing
            for (other_task, other_taskdeps) in queue.dependencies
                if task === other_task
                    for (readdep, writedep, other_spans) in other_taskdeps
                        writedep || continue
                        any(will_alias(span, other_span) for span in arg_to_spans[arg], other_span in other_spans) || continue
                        return true
                    end
                    return false
                end
            end
        else
            for ((readdep, writedep), other_task) in queue.deps[arg]
                if task === other_task
                    return writedep
                end
            end
        end
        error("Task isn't in argdeps set")
    end

    # Get the set of all processors to be scheduled on
    all_procs = Processor[]
    all_spaces_set = Set{MemorySpace}()
    scope = get_options(:scope, DefaultScope())
    for w in procs()
        append!(all_procs, get_processors(OSProc(w)))
    end
    filter!(proc->!isa(constrain(ExactScope(proc), scope),
                       InvalidScope),
            all_procs)
    if any(proc->!isa(proc, ThreadProc), all_procs)
        @warn "Non-CPU execution not yet supported by `spawn_datadeps`; non-CPU processors will be ignored" maxlog=1
        filter!(proc->!isa(proc, ThreadProc), all_procs)
    end
    for proc in all_procs
        for space in memory_spaces(proc)
            push!(all_spaces_set, space)
        end
    end
    all_spaces = collect(all_spaces_set)

    # Track original and current data locations
    # We track data => space
    data_origin = IdDict{Any,MemorySpace}(data=>memory_space(data) for data in keys(queue.deps) if !isa(data, EagerThunk) || istaskstarted(data))
    data_locality = IdDict{Any,MemorySpace}(data=>memory_space(data) for data in keys(queue.deps) if !isa(data, EagerThunk) || istaskstarted(data))

    # Track writers ("owners") and readers
    args_tracked = IdDict{Any,Bool}()
    if queue.aliasing
        spans_owner = Dict{MemorySpan,Union{EagerThunk,Nothing}}()
        spans_readers = Dict{MemorySpan,Vector{EagerThunk}}()
    else
        args_owner = IdDict{Any,Union{EagerThunk,Nothing}}()
        args_readers = IdDict{Any,Vector{EagerThunk}}()
    end
    function populate_owner_readers!(arg)
        haskey(args_tracked, arg) && return
        args_tracked[arg] = true
        if queue.aliasing
            haskey(arg_to_spans, arg) || return
            for span in arg_to_spans[arg]
                spans_owner[span] = nothing
                spans_readers[span] = EagerThunk[]
            end
        else
            args_owner[arg] = nothing
            args_readers[arg] = EagerThunk[]
        end
    end
    for arg in keys(queue.deps)
        arg isa EagerThunk && !istaskstarted(arg) && continue
        populate_owner_readers!(arg)
    end

    function get_write_deps!(arg, syncdeps)
        haskey(args_tracked, arg) || return
        if queue.aliasing
            for span in arg_to_spans[arg]
                for (other_arg, other_spans) in arg_to_spans
                    for other_span in other_spans
                        will_alias(span, other_span) || continue
                        if (owner = spans_owner[other_span]) !== nothing
                            push!(syncdeps, owner)
                        end
                        for reader in spans_readers[other_span]
                            push!(syncdeps, reader)
                        end
                    end
                end
            end
        else
            if (owner = args_owner[arg]) !== nothing
                push!(syncdeps, owner)
            end
            for reader in args_readers[arg]
                push!(syncdeps, reader)
            end
        end
    end
    function get_read_deps!(arg, syncdeps)
        haskey(args_tracked, arg) || return
        if queue.aliasing
            for span in arg_to_spans[arg]
                for (other_arg, other_spans) in arg_to_spans
                    for other_span in other_spans
                        will_alias(span, other_span) || continue
                        if (owner = spans_owner[other_span]) !== nothing
                            push!(syncdeps, owner)
                        end
                    end
                end
            end
        else
            if (owner = args_owner[arg]) !== nothing
                push!(syncdeps, owner)
            end
        end
    end
    function add_writer!(arg, task)
        if queue.aliasing
            for span in arg_to_spans[arg]
                spans_owner[span] = task
                empty!(spans_readers[span])
                # Not necessary, but conceptually it's true
                # It also means we don't need an extra `add_reader!` call
                push!(spans_readers[span], task)
            end
        else
            args_owner[arg] = task
            empty!(args_readers[arg])
            # Not necessary, but conceptually it's true
            # It also means we don't need an extra `add_reader!` call
            push!(args_readers[arg], task)
        end
    end
    function add_reader!(arg, task)
        if queue.aliasing
            for span in arg_to_spans[arg]
                push!(spans_readers[span], task)
            end
        else
            push!(args_readers[arg], task)
        end
    end

    # Make a copy of each piece of data on each worker
    # memory_space => {arg => copy_of_arg}
    remote_args = Dict{MemorySpace,IdDict{Any,Any}}(space=>IdDict{Any,Any}() for space in all_spaces)
    function generate_slot!(space, data)
        if data isa EagerThunk
            data = fetch(data; raw=true)
        end
        data_space = memory_space(data)
        if data_space == space
            return Dagger.tochunk(data)
        else
            # TODO: Can't use @mutable with custom Chunk scope
            #remote_args[w][data] = Dagger.@mutable worker=w copy(data)
            to_proc = first(processors(space))
            from_proc = first(processors(data_space))
            w = only(unique(map(get_parent, collect(processors(space))))).pid
            return remotecall_fetch(w, from_proc, to_proc, data) do from_proc, to_proc, data
                data_raw = fetch(data)
                data_converted = move(from_proc, to_proc, data_raw)
                return Dagger.tochunk(data_converted)
            end
        end
    end
    for space in all_spaces
        this_space_args = remote_args[space] = IdDict{Any,Any}()
        for data in keys(queue.deps)
            data isa EagerThunk && !istaskstarted(data) && continue
            has_writedep(data) || continue
            this_space_args[data] = generate_slot!(space, data)
        end
    end

    # Round-robin assign tasks to processors
    proc_idx = 1
    upper_queue = get_options(:task_queue)

    traversal = queue.traversal
    if traversal == :inorder
        # As-is
        task_order = Colon()
    elseif traversal == :bfs
        # BFS
        task_order = Int[1]
        to_walk = Int[1]
        seen = Set{Int}([1])
        while !isempty(to_walk)
            # N.B. next_root has already been seen
            next_root = popfirst!(to_walk)
            for v in outneighbors(queue.g, next_root)
                if !(v in seen)
                    push!(task_order, v)
                    push!(seen, v)
                    push!(to_walk, v)
                end
            end
        end
    elseif traversal == :dfs
        # DFS (modified with backtracking)
        task_order = Int[]
        to_walk = Int[1]
        seen = Set{Int}()
        while length(task_order) < length(queue.seen_tasks) && !isempty(to_walk)
            next_root = popfirst!(to_walk)
            if !(next_root in seen)
                iv = inneighbors(queue.g, next_root)
                if all(v->v in seen, iv)
                    push!(task_order, next_root)
                    push!(seen, next_root)
                    ov = outneighbors(queue.g, next_root)
                    prepend!(to_walk, ov)
                else
                    push!(to_walk, next_root)
                end
            end
        end
    else
        throw(ArgumentError("Invalid traversal mode: $traversal"))
    end

    # Start launching tasks and necessary copies
    for (spec, task) in queue.seen_tasks[task_order]
        our_proc = all_procs[proc_idx]
        our_space = only(memory_spaces(our_proc))

        # Spawn copies before user's task, as necessary
        @dagdebug nothing :spawn_datadeps "($(spec.f)) Scheduling: $our_proc ($our_space)"
        task_args = copy(spec.args)

        # Copy args from local to remote
        for (idx, (pos, arg)) in enumerate(task_args)
            # Is the data written previously or now?
            populate_writedeps!(arg)
            populate_owner_readers!(arg)
            if !has_writedep(arg, task)
                @dagdebug nothing :spawn_datadeps "($(spec.f))[$idx] Skipped copy-to (unwritten)"
                continue
            end

            data_space = data_locality[arg]

            # Is the source of truth elsewhere?
            arg_remote = get!(remote_args[our_space], arg) do
                generate_slot!(our_space, arg)
            end
            nonlocal = our_space != data_space
            if nonlocal
                # Add copy-to operation (depends on latest owner of arg)
                @dagdebug nothing :spawn_datadeps "($(spec.f))[$idx] Enqueueing copy-to: $data_space => $our_space"
                arg_local = get!(remote_args[data_space], arg) do
                    generate_slot!(data_space, arg)
                end
                copy_to_scope = ExactScope(our_proc)
                copy_to_syncdeps = Set{Any}()
                get_write_deps!(arg, copy_to_syncdeps)
                @dagdebug nothing :spawn_datadeps "($(spec.f))[$idx] $(length(copy_to_syncdeps)) syncdeps"
                # TODO: copy_to = Dagger.@spawn scope=copy_to_scope syncdeps=copy_to_syncdeps Dagger.move!(our_space, data_space, arg_remote, arg_local)
                copy_to = Dagger.@spawn scope=copy_to_scope syncdeps=copy_to_syncdeps copyto!(arg_remote, arg_local)
                add_writer!(arg, copy_to)

                data_locality[arg] = our_space
            else
                @dagdebug nothing :spawn_datadeps "($(spec.f))[$idx] Skipped copy-to (local): $data_space"
            end
            spec.args[idx] = pos => arg_remote
        end

        # Validate that we're not accidentally performing a copy
        for (idx, (_, arg)) in enumerate(spec.args)
            if is_writedep(arg, task)
                arg_space = memory_space(arg)
                @assert arg_space == our_space "($(spec.f))[$idx] Tried to pass $(typeof(arg)) from $arg_space to $our_space"
            end
        end

        # Launch user's task
        spec.f = move(ThreadProc(myid(), 1), our_proc, spec.f)
        syncdeps = get(Set{Any}, spec.options, :syncdeps)
        for (idx, (_, arg)) in enumerate(task_args)
            if is_writedep(arg, task)
                @dagdebug nothing :spawn_datadeps "($(spec.f))[$idx] Sync with owner/readers"
                get_write_deps!(arg, syncdeps)
            else
                get_read_deps!(arg, syncdeps)
            end
        end
        @dagdebug nothing :spawn_datadeps "($(spec.f)) $(length(syncdeps)) syncdeps"
        task_scope = Dagger.ExactScope(our_proc)
        spec.options = merge(spec.options, (;syncdeps, scope=task_scope))
        enqueue!(upper_queue, spec=>task)

        # Update read/write tracking for arguments
        for (idx, (_, arg)) in enumerate(task_args)
            if is_writedep(arg, task)
                @dagdebug nothing :spawn_datadeps "($(spec.f))[$idx] Set as owner"
                add_writer!(arg, task)
            else
                add_reader!(arg, task)
            end
        end

        # Update read/write/locality tracking for result
        populate_writedeps!(task)
        populate_owner_readers!(task)
        add_writer!(task, task)
        data_locality[task] = our_space
        data_origin[task] = our_space

        # Select the next processor to use
        proc_idx = mod1(proc_idx+1, length(all_procs))
    end

    # Copy args from remote to local
    for arg in keys(queue.deps)
        # Is the data previously written?
        populate_writedeps!(arg)
        populate_owner_readers!(arg)
        if !has_writedep(arg)
            @dagdebug nothing :spawn_datadeps "Skipped copy-from (unwritten)"
        end

        # Is the source of truth elsewhere?
        data_remote_space = data_locality[arg]
        data_local_space = data_origin[arg]
        if data_local_space != data_remote_space
            # Add copy-from operation
            @dagdebug nothing :spawn_datadeps "Enqueueing copy-from: $data_remote_space => $data_local_space"
            arg_local = remote_args[data_local_space][arg]
            arg_remote = remote_args[data_remote_space][arg]
            @assert arg_remote !== arg_local
            data_local_proc = first(processors(data_local_space))
            copy_from_scope = ExactScope(data_local_proc)
            copy_from_syncdeps = Set()
            get_write_deps!(arg, copy_from_syncdeps)
            @dagdebug nothing :spawn_datadeps "$(length(copy_from_syncdeps)) syncdeps"
            # TODO: copy_from = Dagger.@spawn scope=copy_from_scope syncdeps=copy_from_syncdeps Dagger.move!(data_local_space, data_remote_space, arg_local, arg_remote)
            copy_from = Dagger.@spawn scope=copy_from_scope syncdeps=copy_from_syncdeps copyto!(arg_local, arg_remote)
        else
            @dagdebug nothing :spawn_datadeps "Skipped copy-from (local): $data_remote_space"
        end
    end
end

"""
    spawn_datadeps(f::Base.Callable; static::Bool=true, traversal::Symbol=:inorder)

Constructs a "datadeps" (data dependencies) region and calls `f` within it.
Dagger tasks launched within `f` may wrap their arguments with `In`, `Out`, or
`InOut` to indicate whether the task will read, write, or read+write that
argument, respectively. These argument dependencies will be used to specify
which tasks depend on each other based on the following rules:

- Dependencies across different arguments are independent; only dependencies on the same argument synchronize with each other ("same-ness" is determined based on `isequal`)
- `InOut` is the same as `In` and `Out` applied simultaneously, and synchronizes with the union of the `In` and `Out` effects
- Any two or more `In` dependencies do not synchronize with each other, and may execute in parallel
- An `Out` dependency synchronizes with any previous `In` and `Out` dependencies
- An `In` dependency synchronizes with any previous `Out` dependencies
- If unspecified, an `In` dependency is assumed

In general, the result of executing tasks following the above rules will be
equivalent to simply executing tasks sequentially and in order of submission.
Of course, if dependencies are incorrectly specified, undefined behavior (and
unexpected results) may occur.

Unlike other Dagger tasks, tasks executed within a datadeps region are allowed
to write to their arguments when annotated with `Out` or `InOut`
appropriately.

At the end of executing `f`, `spawn_datadeps` will wait for all launched tasks
to complete, rethrowing the first error, if any. The result of `f` will be
returned from `spawn_datadeps`.

The keyword argument `static` can be set to `false` to use the simpler dynamic
schedule - its usage is experimental and is subject to change.

The keyword argument `traversal` controls the order that tasks are launched by
the static scheduler, and may be set to `:bfs` or `:dfs` for Breadth-First
Scheduling or Depth-First Scheduling, respectively. All traversal orders
respect the dependencies and ordering of the launched tasks, but may provide
better or worse performance for a given set of datadeps tasks. This argument
is experimental and subject to change.
"""
function spawn_datadeps(f::Base.Callable; static::Bool=true,
                        traversal::Symbol=:inorder, aliasing::Bool=true)
    wait_all(; check_errors=true) do
        queue = DataDepsTaskQueue(get_options(:task_queue, EagerTaskQueue());
                                  static, traversal, aliasing)
        result = with_options(f; task_queue=queue)
        if queue.static
            distribute_tasks!(queue)
        end
        return result
    end
end
