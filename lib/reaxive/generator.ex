defmodule Reaxive.Generator do
	@moduledoc """
	This module collects functions for generating a sequence of events. These generators 
	are always the roots of the event sequence network, they do not subscribe to other 
	sequences. However, often they use other data sources such a stream, an IO connection
	or the like. 

	Generators have the important feature of being canceable. This means that their generation 
	process can be canceled from the outside. This is important for freeing up any other 
	resources used the generator while producing new events. 
	"""

	@type accu_t :: any
	@typedoc "Generator function to be used by `Reaxive.Rx.delayed_start`"
	@type generator_fun_t :: (() -> any

	@doc """
	Generates new values by calling `prod_fun` and sending them to `rx`. 
	If canceled (by receiving`:cancel`), the `abort_fun` is called. Between
	two events a `delay`, measured in milliseconds, takes place. 

	This function assumes an infinite generator. There is no means for finishing
	the generator except for canceling. 
	"""
	@spec generate(Observer.t, (()-> any), (()-> any), pos_integer) :: any
	def generate(rx, prod_fun, abort_fun, delay) do
		receive do
			:cancel -> abort_fun.()
		after 0 -> # if :cancel is not there, do not wait for it
			Observer.on_next(rx, prod_fun.())
			:timer.sleep(delay)
			generate(rx, prod_fun, abort_fun, delay)
		end
	end
	
	@doc """
	Generates new values by calling `prod_fun` and sending them to `rx`. 
	If canceled (by receiving`:cancel`), the `abort_fun` is called. Between
	two events a `delay`, measured in milliseconds, takes place. 

	This function assumes an infinite generator. There is no means for finishing
	the generator except for canceling. 
	"""
	@spec generate(Observer.t, ((accu_t)-> {accu_t, any}), (()-> any), accu_t, pos_integer) :: any
	def generate_with_accu(rx, prod_fun, abort_fun, accu, delay) do
		receive do
			:cancel -> abort_fun.()
		after 0 -> # if :cancel is not there, do not wait for it
			{new_accu, value} = prod_fun.(accu)
			Observer.on_next(rx, value)
			:timer.sleep(delay)
			generate(rx, prod_fun, abort_fun, new_accu, delay)
		end
	end

	#############
	### How to deal with 
	###   * finite generators, sending a on_complete after a while
	###   * generators with errors, sending on_error and finishing afterwards?
	### Both are required for IO-Generators!

	@doc """
	Sends a tick every `delay` milliseconds to `rx` 
	"""
	@spec tick(Observer.t, pos_integer) :: generator_fun_t
	def tick(rx, delay), do:
		fn() -> generate(rx, fn() -> :tick end, fn() -> :ok, delay) end


	@doc """
	Enumerates the naturals number starting with `0`. Sends the 
	next number after `delay` milliseconds to `rx`. 
	"""
	@spec naturals(Observer.t, pos_integer) :: generator_fun_t
	def naturals(rx, delay), do: 
		fn() -> generate_with_accu(rx, &({1+&1, 1+&1}), fn() -> :ok, 0, delay) end

end