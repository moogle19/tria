defmodule Tria.Language.Tri do
  @moduledoc """
  Module for famous `tri/2` macro. This macro is used mostly for testing the optimized code

  Development notice:
  tri/2 macro works with Elixir's AST (because it is a Macro and Tria is written in Elixir)
  Therefore it uses `is_elixir_variable` guard and such

  #TODO implement store/restore
  To save the metadata in pattern and restore it in quote
  """

  import Tria.Language
  alias Tria.Compiler.ElixirTranslator
  alias Tria.Compiler.SSATranslator

  @typedoc """
  Options for `tri/2` macro

  - `:debug` — defines label in case you want to inspect the AST (default: `false`)
  - `:to_tria` — translates the pattern to Tria (default: `true`)
  - `:to_ssa` — translates the pattern to SSA form (default: `false`)
  - `:isolate` — defines that the variables should not be fetches from outer context (default: `false`)
  - `:meta` — whether meta field should be empty in pattern or in AST
  """
  @type option ::
          {:debug, atom()}
          | {:to_tria, :force | true | false}
          | {:to_ssa, boolean()}
          | {:isolate, boolean()}
          | {:meta, boolean()}

  @doc """
  `quote/unquote` but on steroids

  This macro behaves differently depending on context it was called in.
  Note that in every context variables are unescaped by default and leading
  `do:` is ignored.

  When called in pattern, this macro takes passed AST and
  transforms it into pattern to match upon. It drops the metadata
  and allows the usage of `tri` inside `tri` to kinda unquote code
  It also supports `tri_splicing` which works kinda like `unquote_splicing`

  Example:
      iex> tri(x + y) = quote do: 1 + 2
      iex> x == 1 and y == 2
      true

  When called outside the pattern, this macro takes passed AST and
  transforms it into pattern to match upon. It drops the metadata
  and allows the usage of `tri` inside `tri` to kinda unquote code.
  It also supports `tri_splicing` which works like `unquote_splicing`.

  Example:
      iex> x = 1; y = 2
      iex> tri(x + y)
      {{:".", [], [Kernel, :+]}, [], [1, 2]}

  See `Tria.Tri.option()` for available options
  """
  @spec tri([option()], Macro.input()) :: Macro.output()
  defmacro tri(opts \\ [], block)

  defmacro tri(opts, do: code) do
    do_tri(code, opts, __CALLER__)
  end

  defmacro tri(opts, code) do
    do_tri(code, opts, __CALLER__)
  end

  def do_tri(code, opts, env) do
    opts = get_defaults(opts, env)

    if Macro.Env.in_match?(env) do
      to_pattern(code, opts, env)
    else
      to_quote(code, opts, env)
    end
    |> tap(fn x ->
      case opts[:debug] do
        v when v in [nil, false] -> nil
        true -> inspect_ast(x)
        label -> inspect_ast(x, label: label)
      end
    end)
  end

  defp to_pattern(quoted, opts, env) do
    quoted
    |> then(fn quoted ->
      case opts[:to_tria] do
        :force -> ElixirTranslator.to_tria!(quoted)
        _ -> quoted
      end
    end)
    |> Macro.escape(prune_metadata: true, unquote: true)
    |> then(fn escaped ->
      unless opts[:isolate] do
        prewalk(escaped, &maybe_unescape_variable/1)
      else
        escaped
      end
    end)
    |> traverse(env)
    |> maybe_untranslate(env, opts)
  end

  defp to_quote(code, opts, %Macro.Env{versioned_vars: versioned_vars} = env) do
    code
    |> maybe_translate(env, opts)
    |> Macro.escape()
    |> then(fn x ->
      unless opts[:isolate] do
        # opts[:debug] && IO.inspect versioned_vars, label: :versioned_vars
        # opts[:debug] && IO.inspect x, label: :x
        prewalk(x, &maybe_unescape_variable(&1, versioned_vars))
      else
        x
      end
    end)
    |> then(fn x ->
      if Keyword.get(opts, :meta, true) do
        x
      else
        prewalk(x, fn
          {:{}, [], [op, _meta, args]} -> {:{}, [], [op, [], args]}
          other -> other
        end)
      end
    end)
  end

  defp maybe_translate(code, env, opts) do
    if Keyword.get(opts, :to_tria, true) do
      tria = ElixirTranslator.to_tria!(code, env)

      if Keyword.get(opts, :to_ssa, true) do
        SSATranslator.from_tria!(tria)
      else
        tria
      end
    else
      code
    end
  end

  defp maybe_untranslate(tria, env, opts) do
    if Keyword.get(opts, :to_tria, true) do
      ElixirTranslator.from_tria(tria, env)
    else
      tria
    end
  end

  ## This function drops meta in escaped AST
  ## and unescapes code

  ### Tri helpers
  defp traverse([{:{}, _, [:tri_splicing, _, [list]]}], env) do
    traverse_in_tri(list, env)
  end

  defp traverse({:{}, _, [:tri, _, [literal]]}, env) do
    traverse_in_tri(literal, env)
  end

  defp traverse({:{}, _, [:tri, _, [n, m, a]]}, env) do
    {:{}, [], [traverse_in_tri(n, env), traverse_in_tri(m, env), traverse_in_tri(a, env)]}
  end

  ### Arbitary escaped AST
  defp traverse([head | tail], env) do
    head = traverse(head, env)
    tail = traverse(tail, env)

    # This case is not necessary, but readability counts here
    case tail do
      tail when is_list(tail) ->
        [head | tail]

      _ ->
        [{:|, [], [head, tail]}]
    end
  end

  defp traverse({l, r}, env) do
    {traverse(l, env), traverse(r, env)}
  end

  defp traverse({:{}, _, [n, _, a]}, env) do
    {:{}, [], [traverse(n, env), metavar(), traverse(a, env)]}
  end

  defp traverse(other, _env), do: other

  ## Traversion for quoted inside `tri/1` and `tri/3`
  ## Basiacally unescapes AST

  defp traverse_in_tri(escaped, env) when is_list(escaped) do
    Enum.map(escaped, &traverse_in_tri(&1, env))
  end

  defp traverse_in_tri({l, r}, env) do
    {traverse_in_tri(l, env), traverse_in_tri(r, env)}
  end

  defp traverse_in_tri({:{}, _, [n, _, a]}, env) do
    Macro.expand({traverse_in_tri(n, env), [], traverse_in_tri(a, env)}, env)
  end

  defp traverse_in_tri(other, _env), do: other

  ## Unescapes variables

  defp maybe_unescape_variable({:{}, _, [n, m, c]}) when is_variable({n, m, c}) do
    {n, m, c}
  end

  defp maybe_unescape_variable(other), do: other

  defp maybe_unescape_variable({:{}, _, [n, m, c]} = original, versioned_vars)
       when is_variable({n, m, c}) do
    name_context = {n, c}
    name_nil = {n, nil}

    case versioned_vars do
      %{^name_context => _} ->
        {n, m, c}

      %{^name_nil => _} ->
        {n, m, nil}

      _ ->
        original
    end
  end

  defp maybe_unescape_variable(other, _), do: other

  ## Other helpers

  defp metavar do
    {:_, [], nil}
  end

  defp get_defaults(opts, %Macro.Env{module: nil}), do: opts

  defp get_defaults(opts, %Macro.Env{module: module}) do
    opts ++ Module.get_attribute(module, :tri_opts, [])
  end
end
