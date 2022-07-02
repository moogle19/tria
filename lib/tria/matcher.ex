defmodule Tria.Matcher do

  @moduledoc """
  Code pattern-matching module
  """

  import Tria.Common

  defmacro tri(do: code) do
    to_pattern(code, __CALLER__)
  end

  defmacro tri(code) do
    to_pattern(code, __CALLER__)
  end

  defmacro tri(:debug, do: code) do
    to_pattern(code, __CALLER__)
    |> inspect_ast()
  end

  defmacro tri(:debug, code) do
    to_pattern(code, __CALLER__)
    |> inspect_ast()
  end

  defp to_pattern(quoted, env) do
    quoted
    |> Macro.escape(prune_metadata: true, unquote: true)
    # |> IO.inspect(label: :unescapeed) # After escape
    |> Macro.prewalk(&maybe_unescape_variable/1)
    |> traverse(env)
  end

  # This function drops meta in escaped AST
  # and unescapes code

  # Tri helpers
  defp traverse({:{}, _, [
    func,
    _,
    [{:{}, _, [:tri_splicing, _, [list]]}]
  ]}, env) do
    {:{}, [], [traverse(func, env), underscore(), traverse(list, env)]}
  end

  # defp traverse({:{}, _, [:tri, _, [n, m, a]]}) do
  #   {:{}, [], [n, m, a]}
  # end
  defp traverse({:{}, _, [:tri, _, [literal]]}, env) do
    traverse_in_tri(literal, env)
  end
  defp traverse({:{}, _, [:tri, _, [n, m, a]]}, env) do
    {:{}, [], [traverse_in_tri(n, env), traverse_in_tri(m, env), traverse_in_tri(a, env)]}
  end

  # Arbitary escaped AST
  defp traverse(escaped, env) when is_list(escaped) do
    Enum.map(escaped, &traverse(&1, env))
  end
  defp traverse({l, r}, env) do
    {traverse(l, env), traverse(r, env)}
  end
  defp traverse({:{}, _, [n, _, a]}, env) do
    {:{}, [], [traverse(n, env), underscore(), traverse(a, env)]}
  end
  defp traverse(other, _env), do: other

  # Traversion for quoted inside `tri/1` and `tri/3`
  # Basiacally unescapes AST
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
  
  # Unescapes variables
  defp maybe_unescape_variable({:{}, _, [n, m, c]}) when is_variable({n, m, c}) do
    {n, m, c}
  end
  defp maybe_unescape_variable(other), do: other

  defp underscore do
    {:_, [], Elixir}
  end

end
