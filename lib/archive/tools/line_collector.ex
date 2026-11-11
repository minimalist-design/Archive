defmodule Archive.Tools.LineCollector do
  @moduledoc """
  A `Collectable` that splits command output into lines and passes each line to
  a callback. Optionally also keeps the full output (`keep: true`).
  """

  defstruct fun: nil, buffer: "", keep: false, acc: []

  def new(fun, opts \\ []), do: %__MODULE__{fun: fun, keep: Keyword.get(opts, :keep, false)}

  @doc "Flushes a trailing partial line and returns the collected output."
  def finish(%__MODULE__{buffer: buffer, fun: fun} = c) do
    if buffer != "" and fun, do: fun.(buffer)
    if c.keep, do: c.acc |> Enum.reverse() |> IO.iodata_to_binary(), else: ""
  end
end

defimpl Collectable, for: Archive.Tools.LineCollector do
  def into(collector) do
    fun = fn
      c, {:cont, data} ->
        acc = if c.keep, do: [data | c.acc], else: c.acc
        {lines, rest} = split(c.buffer <> data)
        if c.fun, do: Enum.each(lines, c.fun)
        %{c | buffer: rest, acc: acc}

      c, :done ->
        c

      _c, :halt ->
        :ok
    end

    {collector, fun}
  end

  defp split(data) do
    parts = String.split(data, ~r/\r\n|\n|\r/)
    {Enum.drop(parts, -1), List.last(parts)}
  end
end
