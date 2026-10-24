defmodule Lotus.Storage.ScheduleDelivery do
  @moduledoc """
  One delivery of a schedule: the channel and the format, by name, and the
  channel's settings. See `Lotus.Delivery`.

  Its `id` is generated when it is added, and keys its outcome on each run.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: String.t(),
          channel: String.t(),
          format: String.t(),
          config: map()
        }

  @primary_key {:id, :binary_id, autogenerate: true}

  json_encoder = Lotus.JSON.encoder()
  @derive {json_encoder, only: [:id, :channel, :format, :config]}

  embedded_schema do
    field(:channel, :string)
    field(:format, :string)
    field(:config, :map, default: %{})
  end

  @doc false
  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [:channel, :format, :config])
    |> validate_required([:channel, :format])
    |> validate_delivery()
  end

  defp validate_delivery(%{valid?: false} = changeset), do: changeset

  defp validate_delivery(changeset) do
    case Lotus.Delivery.validate(
           get_field(changeset, :channel),
           get_field(changeset, :format),
           get_field(changeset, :config)
         ) do
      :ok -> changeset
      {:error, field, message} -> add_error(changeset, field, message)
    end
  end
end
