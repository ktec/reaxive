defmodule Reaxive.Rx.Impl do

	use GenServer
	require Logger

	@moduledoc """
	Implements the Rx protocols and handles the contract.
	"""

	@typedoc """
	Internal message for propagating events.
	"""
	@type rx_propagate :: {:on_next, term} | {:on_error, term} | {:on_completed, nil}
	@typedoc """
	Tags for interacting between reduce-function and its reducers. They have the following
	implications:

	* `:cont`: continue with the iteration and send the current value to subscribers
	* `:ignore`: continue the iteration, but do not set anything to subscribers (i.e. ignore the value)
	* `:halt`: stop the iteration and send the current value to subscribers
	"""
	@type reduce_tag :: :cont | :halt | :ignore
	@typedoc "Return value of reducers"
	@type reducer :: {reduce_tag, rx_propagate, term}

	@type t :: %__MODULE__{}

	@derive Access
	defstruct name: nil, # might be handy to identify the Rx?
		active: true, # if false, then an error has occurred or the calculation is completed
		subscribers: [], # all interested observers
		sources: [], # list of disposables
		action: nil, # the function to be applied to the values
		options: [], #  behavior options,
		queue: nil, # outbound queue before any subscriber is available
		on_subscribe: nil, # function called at first subscription
		accu: [] # accumulator

	@doc """
	Starts the Rx Impl. If `auto_stop` is true, the `Impl` finishes after completion or
	after an error or after unsubscribing the last subscriber.
	"""
	def start(), do: start(nil, [auto_stop: true])
	def start(name, options), do:
		GenServer.start(__MODULE__, [name, options])

	def init([name, options]) do
		s = %__MODULE__{name: name, options: options}
		# Logger.info "init - state = #{inspect s}"
		{:ok, s}
	end

	@doc """
	Subscribes a new observer. Returns a function for unsubscribing the observer.

	Fails grafecully with an `on_error` message to the observer, if the
	observable is not or no longer available. In this case, an do-nothing unsubciption
	functions is returned (since no subscription has occured in the first place).
	"""
	@spec subscribe(Observable.t, Observer.t) :: {PID, (() -> :ok)}
	def subscribe(observable, observer) do
		# dispose_fun is defined first to circumevent a problem in Erlang's cover-tool,
		# which does not work if after an try-block in Elixir an additional statement is
		# in the function.
		dispose_fun = fn() ->
			try do
				unsubscribe(observable, observer)
			catch
				:exit, _code -> :ok # Logger.debug "No process #{inspect observable} - no problem #{inspect code}"
			end
		end
		try do
			:ok = GenServer.cast(observable, {:subscribe, observer})
			{observable, dispose_fun}
		catch
			:exit, {fail, {GenServer, :call, _}} when fail in [:normal, :noproc] ->
				Logger.debug "subscribe failed because observable #{inspect observable} does not exist anymore"
				Logger.debug Exception.format_stacktrace()
				Observer.on_error(observer, :subscribe_failed)
				{observable, fn() -> :ok end}
		end
	end

	@doc """
	Unsubscribes an `observer` from the event sequence.
	"""
	def unsubscribe(observable, observer), do:
		GenServer.call(observable, {:unsubscribe, observer})

	@doc """
	Sets the disposable event sequence `source`. This is needed for proper unsubscribing
	from the `source` when terminating the sequence.
	"""
	def source(observable, disposable) do
		try do
			GenServer.cast(observable, {:source, disposable})
		catch
			:exit, {fail, {GenServer, :call, _}} when fail in [:normal, :noproc] ->
				Logger.debug "source failed because observable does not exist anymore"
				Disposable.dispose disposable
		end
	end

	@doc """
	This function sets the internal action on received events before the event is
	propagated to the subscribers. An initial accumulator value can also be provided.
	"""
	def fun(observable, fun, acc \\ []), do:
		GenServer.call(observable, {:fun, fun, acc})

	@doc """
	Composes the internal action on received events with the given `fun`. The
	initial function to compose with is the identity function.
	"""
	def compose(observable, {fun, acc}) do
		:ok = GenServer.call(observable, {:compose, fun, acc})
		observable
	end
	def compose(observable, fun, acc), do:
		GenServer.call(observable, {:compose, fun, acc})

	@doc "All subscribers of Rx. Useful for debugging."
	def subscribers(observable), do: GenServer.call(observable, :subscribers)

	@doc "All sources of Rx. Useful for debugging."
	def get_sources(observable), do: GenServer.call(observable, :get_sources)

	@doc "Returns the number of active sources"
	def count_sources(observable), do: GenServer.call(observable, :count_sources)

	@doc "Sets the on_subscribe function, which is called for the first subscription."
	def on_subscribe(observable, on_subscribe), do:
		GenServer.call(observable, {:on_subscribe, on_subscribe})

	@doc "All request-reply calls for setting up the Rx."
	def handle_call({:unsubscribe, observer}, _from, %__MODULE__{subscribers: sub} = state) do
		new_sub = List.delete(sub, observer)
		new_state = %__MODULE__{state | subscribers: new_sub}
		case terminate?(new_state) do
			true  -> {:stop, :normal, new_state}
			false -> {:reply, :ok, new_state}
		end
	end
	def handle_call({:fun, fun, acc}, _from, %__MODULE__{action: nil}= state), do:
		{:reply, :ok, %__MODULE__{state | action: fun, accu: acc}}
	def handle_call({:compose, fun, acc}, _from, %__MODULE__{action: nil, accu: []}= state), do:
		{:reply, :ok, %__MODULE__{state | action: fun, accu: [acc]}}
	def handle_call({:compose, fun, acc}, _from, %__MODULE__{action: g, accu: accu}= state), do:
		{:reply, :ok, %__MODULE__{state | action: fn(x) -> fun . (g . (x)) end, accu: :lists.append(accu, [acc])}}
	def handle_call(:subscribers, _from, %__MODULE__{subscribers: sub} = s), do: {:reply, sub, s}
	def handle_call(:count_sources, _from, %__MODULE__{sources: src} = s), do:
		{:reply, length(src), s}
	def handle_call(:get_sources, _from, %__MODULE__{sources: src} = s), do:
		{:reply, src, s}
	def handle_call({:on_subscribe, fun}, _from, %__MODULE__{on_subscribe: nil}= state), do:
		{:reply, :ok, %__MODULE__{state | on_subscribe: fun}}

	@doc "Process the next value"
	def on_next(observer, value), do:
		:ok = GenServer.cast(observer, {:on_next, value})

	@doc "The last regular message"
	def on_completed(observer, observable), do:
		:ok = GenServer.cast(observer, {:on_completed, observable})

	@doc "An error has occured, the pipeline will be aborted."
	def on_error(observer, exception), do:
		:ok = GenServer.cast(observer, {:on_error, exception})

	@doc "Asynchronous callback. Used for processing values and subscription."
	def handle_cast({:subscribe, observer},
			%__MODULE__{subscribers: [], on_subscribe: nil} = state), do:
		do_subscribe(state, observer)
	def handle_cast({:subscribe, observer},
			%__MODULE__{subscribers: [], on_subscribe: on_subscribe} = state) do
		# If the on_subscribe hook is set, we call it on first subscription.
		# Introduced for properly implementing the Enum/Stream generator
		on_subscribe.()
		do_subscribe(state, observer)
	end
	def handle_cast({:subscribe, observer}, %__MODULE__{} = state), do:
		do_subscribe(state, observer)
	def handle_cast({:source, disposable}, %__MODULE__{sources: []}= state) when is_list(disposable), do:
		{:noreply, %__MODULE__{state | sources: disposable}}
	def handle_cast({:source, disposable}, %__MODULE__{sources: src}= state) when is_list(disposable), do:
		{:noreply, %__MODULE__{state | sources: disposable ++ src}}
	def handle_cast({:source, disposable}, %__MODULE__{sources: src}= state), do:
		{:noreply, %__MODULE__{state | sources: [disposable | src]}}
	def handle_cast({_tag, _v} = value, state) do
		Logger.info "RxImpl #{inspect self} got message #{inspect value} in state #{inspect state}"
		handle_event(state, value)
	end


	@doc """
	Internal function to handles the various events, in particular disconnects
	the source which is sending a `on_completed`.
	"""
	@spec handle_event(%__MODULE__{}, rx_propagate) ::
						{:noreply, %__MODULE__{}} | {:stop, :normal, %__MODULE__{}}
	def handle_event(%__MODULE__{} = state, {:on_completed, src} = event) do
		state |>
		 	disconnect_source(src) |>
			handle_value({:on_completed, nil})
	end
	def handle_event(%__MODULE__{} = state, event), do:	handle_value(state, event)

	@doc """
	Internal function to handle new values, errors or completions. If `state.action` is
	`:nil`, the value is propagated without any modification.
	"""
	@spec handle_value(%__MODULE__{}, rx_propagate) :: {:noreply, %__MODULE__{}} | {:stop, :normal, %__MODULE__{}}
	def handle_value(%__MODULE__{active: true} = state, e = {:on_error, _exception}) do
		notify({:cont, e}, state) |> disconnect_all()
	end
	def handle_value(%__MODULE__{active: true, action: fun, accu: accu} = state, value) do
		try do
			# Logger.debug "Handle_value with v=#{inspect value} and #{inspect state}"
			{tag, new_v, new_accu} = case do_action(fun, value, accu, []) do
				{val, acc, new_acc}      -> {:cont, val, new_acc}
				{tag, val, acc, new_acc} -> {tag, val, new_acc}
			end
			new_state = %__MODULE__{
				notify({tag, new_v}, state) |	accu: :lists.reverse(new_accu)}
			case tag do
				:halt -> disconnect_all(new_state)
				_ -> {:noreply, new_state}
			end
		catch
			what, message ->
				Logger.error "Got exception: #{inspect what}, #{inspect message} \n" <>
					"with value #{inspect value} in state #{inspect state}\n" <>
					Exception.format(what, message)
				handle_value(state, {:on_error, {what, message}})
		end
	end
	def handle_value(%__MODULE__{active: false} = state, _value), do: {:noreply, state}

	def do_action(nil, event = {:on_completed, nil}, accu, new_accu), do:
		{:halt, event, [], new_accu}
	def do_action(nil, event, accu, new_accu), do: {event, [], new_accu}
	def do_action(fun, event, accu, new_accu) when is_function(fun, 1),
		do: fun . ({event, accu, new_accu})

	@doc "Internal callback function at termination for clearing resources"
	def terminate(reason, state) do
		Logger.info("Terminating #{inspect self} for reason #{inspect reason} in state #{inspect state}")
	end


	@doc "Internal function to disconnect from the sources"
	@spec disconnect_all(%__MODULE__{}) :: {:noreply, %__MODULE__{}} | {:stop, :normal, %__MODULE__{}}
	def disconnect_all(%__MODULE__{active: true, sources: src} = state) do
		Logger.info("disconnecting all from #{inspect state}")
		src |> Enum.each fn({_id, disp}) -> Disposable.dispose(disp) end
		new_state = %__MODULE__{state | active: false, subscribers: []}
		if terminate?(new_state),
			do: {:stop, :normal, new_state},
			else: {:noreply, new_state}
	end
	# disconnecting from a disconnected state does not change anything
	def disconnect_all(%__MODULE__{active: false, subscribers: []} = state) do
		if terminate?(state),
			do: {:stop, :normal, state},
			else: {:noreply, state}
	end

	@doc """
	Internal function for disconnecting a single source. This function
	does not change anything beyond the `sources` field, in particular
	no decision about inactivating or even stopping the event sequence
	is taken.
	"""
	@spec disconnect_source(%__MODULE__{}, any) :: %__MODULE__{}
	def disconnect_source(%__MODULE__{sources: src} = state, src_id) do
		Logger.info("disconnecting #{inspect src_id} from #{inspect state}")
		new_src = src |> Enum.filter fn({id, _}) -> id == src_id end
		%__MODULE__{state | sources: new_src }
	end


	@doc "Internal function for subscribing a new `observer`"
	def do_subscribe(%__MODULE__{subscribers: sub}= state, observer) do
		# Logger.info "RxImpl #{inspect self} subscribes to #{inspect observer} in state #{inspect state}"
		{:noreply,%__MODULE__{state | subscribers: [observer | sub]}}
	end

	@doc "Internal function to notify subscribers, knows about ignoring notifies."
	def notify({:ignore, _}, state), do: state
	def notify({:cont, ev = {:on_next, value}}, s = %__MODULE__{}), do:	emit(s, ev)
	def notify({:cont, ev = {:on_error, exception}}, s = %__MODULE__{}), do: emit(s, ev)
	def notify({:cont, ev = {:on_completed, nil}}, %__MODULE__{} = state) do
		Logger.info(":cont call on completed in #{inspect self}: #{inspect state} ")
		emit(state, ev)
	end
	def notify({:cont, {:on_completed, value}}, s = %__MODULE__{}), do:
		s |> emit({:on_next, value}) |> emit({:on_completed, self})
	def notify({:halt, {:on_next, value}}, s = %__MODULE__{}), do:
		s |> emit({:on_next, value}) |> emit({:on_completed, self})
	def notify({:halt, {:on_completed, nil}}, %__MODULE__{} = state) do
		Logger.info(":halt call on completed in #{inspect self}: #{inspect state} ")
		state |> emit({:on_completed, self})
	end

	@doc "Either emits a value or puts it into the queue"
	@spec emit(t, rx_propagate) :: t
	def emit(s = %__MODULE__{queue: nil, subscribers: sub}, {:on_next, value}) do
		sub |> Enum.each(&Observer.on_next(&1, value))
		s
	end
	def emit(s = %__MODULE__{queue: nil, subscribers: sub}, {:on_completed, _value}) do
		sub |> Enum.each(&Observer.on_completed(&1, self))
		s
	end
	def emit(s = %__MODULE__{queue: nil, subscribers: sub}, {:on_error, value}) do
		sub |> Enum.each(&Observer.on_error(&1, value))
		s
	end
	def emit(s = %__MODULE__{queue: q, subscribers: []}, event) do
		%__MODULE__{s | queue: :queue.in(event, q)}
	end
	def emit(s = %__MODULE__{queue: q, subscribers: sub}, ev) do
		events = :queue.to_list(q)
		new_s = %__MODULE__{s | queue: nil}
		events |>
			# emit all enqued events
			Enum.reduce(new_s, fn(state, e) -> emit(state, e) end) |>
			# and finally the new event
			emit(ev)
	end

	@doc "Internal predicate to check if we terminate ourselves."
	def terminate?(%__MODULE__{options: options, subscribers: []}) do
		Keyword.get(options, :auto_stop, false)
	end
	def terminate?(%__MODULE__{options: options, active: false}) do
		Keyword.get(options, :auto_stop, false)
	end
	def terminate?(%__MODULE__{}), do: false


	defimpl Disposable, for: Function do
		def dispose(fun), do: fun.()
	end

	defimpl Observer, for: PID do
		def on_next(observer, value), do:      Reaxive.Rx.Impl.on_next(observer, value)
		def on_error(observer, exception), do: Reaxive.Rx.Impl.on_error(observer, exception)
		def on_completed(observer, observable), do:        Reaxive.Rx.Impl.on_completed(observer, observable)
	end

	defimpl Observable, for: PID do
		def subscribe(observable, observer), do: Reaxive.Rx.Impl.subscribe(observable, observer)
	end

	defimpl Observer, for: Function do
		def on_next(observer, value), do: observer.(:on_next, value)
		def on_error(observer, exception), do: observer.(:on_error, exception)
		def on_completed(observer, observable), do: observer.(:on_completed, observable)
	end
end
