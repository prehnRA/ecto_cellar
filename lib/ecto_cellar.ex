defmodule EctoCellar do
  @moduledoc """
  Core module for EctoCellar.
  Handles versions table created by `mix ecto_cellar.gen`.
  You can use this module to store in the cellar and restore the version.
  For a model whose primary_key is other than `id`, specify `id_type` and use it.

  ## Options
   - repo:　You can select a repo other than the one specified in Config.
   - id_type: If the primary key is other than `id`, specify it.
  """

  alias EctoCellar.Version
  alias Ecto.Multi
  @native_datetime_prefix "ecto_cellar_native_datetime_"
  @type options :: [id_type: atom(), repo: module()]

  @doc """
  Stores the changes at that time in the cellar.
  """
  @spec store(struct(), options) :: {:ok, struct()} | {:error, term()}
  def store(%mod{} = model, opts \\ []) do
    Version.create(
      %{
        model_name: mod |> inspect(),
        model_id: model_id(model, opts),
        model_inserted_at: model.inserted_at,
        version: model |> cast_format_map |> Jason.encode!()
      },
      repo(opts)
    )
    |> case do
      {:ok, _version} -> {:ok, model}
      error -> error
    end
  end

  @doc """
  Like store/2, except that if the record is invalid, raises an exception.
  """
  @spec store!(struct(), options) :: struct()
  def store!(%mod{} = model, opts \\ []) do
    Version.create!(
      %{
        model_name: mod |> inspect(),
        model_id: model_id(model, opts),
        model_inserted_at: model.inserted_at,
        version: model |> cast_format_map |> Jason.encode!()
      },
      repo(opts)
    )

    model
  end

  @spec insert_and_store(struct(), options) :: {:ok, struct()} | {:error, term()}
  def insert_and_store(changeset, opts \\ []) do
    Multi.new()
    |> Multi.run(:model, fn _repo, _ -> repo(opts).insert(changeset) end)
    |> Multi.run(:store, fn _repo, %{model: model} -> store(model, opts) end)
    |> repo(opts).transaction()
    |> case do
      {:ok, %{model: model}} ->
        {:ok, model}

      error ->
        error
    end
  end

  @spec update_and_store(struct(), options) :: {:ok, struct()} | {:error, term()}
  def update_and_store(changeset, opts \\ []) do
    Multi.new()
    |> Multi.run(:model, fn _repo, _ -> repo(opts).update(changeset) end)
    |> Multi.run(:store, fn _repo, %{model: record} -> store(record, opts) end)
    |> repo(opts).transaction()
    |> case do
      {:ok, %{model: model}} ->
        {:ok, model}

      error ->
        error
    end
  end

  @doc """
  Returns a specific version of model from the cellar.
  """
  @spec one(struct(), NaiveDateTime.t(), options) :: struct()
  def one(%mod{} = model, timestamp, opts \\ []) do
    Version.one(
      mod |> inspect(),
      timestamp,
      model |> Map.fetch!(id_type(opts)) |> to_string(),
      repo(opts)
    )
    |> to_model(mod)
  end

  @doc """
  Returns all versions of model from the cellar.
  """
  @spec all(struct(), options) :: list(struct())
  def all(%mod{} = model, opts \\ []) do
    Version.all(
      mod |> inspect(),
      model |> Map.fetch!(id_type(opts)) |> to_string(),
      repo(opts)
    )
    |> to_models(mod)
  end

  def repo,
    do:
      Application.get_env(:ecto_cellar, :default_repo) || Application.get_env(:ecto_cellar, :repo)

  defp id_type(opts) when is_list(opts), do: opts[:id_type] || :id
  defp id_type(opts), do: opts

  defp repo(opts) when is_list(opts), do: opts[:repo] || EctoCellar.repo()
  defp repo(_), do: EctoCellar.repo()

  defp model_id(model, opts) do
    if id = Map.fetch!(model, id_type(opts)), do: to_string(id)
  end

  defp to_models(versions, mod) do
    versions
    |> Enum.map(&to_model(&1, mod))
  end

  defp to_model(version, mod) do
    version =
      Jason.decode!(version.version)
      |> Enum.map(fn {key, value} ->
        {
          key |> String.to_existing_atom(),
          if(is_stored_native_datetime(value), do: restore_native_datetime(value), else: value)
        }
      end)

    struct(
      mod.__struct__,
      version
    )
  end

  defp cast_format_map(%{__meta__: %{schema: schema}} = model) do
    for field <- schema.__schema__(:fields),
        into: %{} do
      {field, maybe_encode_native_datetime(Map.get(model, field))}
    end
  end

  defp maybe_encode_native_datetime(%NaiveDateTime{} = value),
    do: "#{@native_datetime_prefix}#{value}"

  defp maybe_encode_native_datetime(value), do: value

  defp is_stored_native_datetime(datetime_str),
    do: to_string(datetime_str) =~ @native_datetime_prefix

  defp restore_native_datetime(datetime_str) do
    datetime_str
    |> String.replace(@native_datetime_prefix, "")
    |> NaiveDateTime.from_iso8601!()
  end
end
