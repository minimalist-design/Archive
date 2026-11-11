defmodule Archive.Repo.Migrations.CreateArchiveTables do
  use Ecto.Migration

  def change do
    create table(:settings, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :map, null: false
      timestamps(type: :utc_datetime)
    end

    create table(:libraries) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :text
      add :source_url, :string
      add :last_synced_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:libraries, [:slug])

    create table(:categories) do
      add :library_id, references(:libraries, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :position, :integer, null: false, default: 0
      timestamps(type: :utc_datetime)
    end

    create unique_index(:categories, [:library_id, :name])

    create table(:videos) do
      add :library_id, references(:libraries, on_delete: :delete_all), null: false
      add :extractor_key, :string, null: false
      add :remote_id, :string
      add :webpage_url, :string
      add :title, :string, null: false
      add :description, :text
      add :uploader, :string
      add :channel, :string
      add :upload_date, :date
      add :duration, :integer
      add :tags, {:array, :string}, null: false, default: []
      add :language, :string
      add :width, :integer
      add :height, :integer
      add :fps, :float
      add :vcodec, :string
      add :acodec, :string
      add :container, :string
      add :filesize, :integer
      add :file_path, :string, null: false
      add :info_json_path, :string
      add :thumbnail_path, :string
      add :playback, :string, null: false, default: "direct"
      add :status, :string, null: false, default: "ready"
      add :metadata, :map, null: false, default: %{}
      add :downloaded_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:videos, [:extractor_key, :remote_id],
             where: "remote_id IS NOT NULL",
             name: :videos_extractor_key_remote_id_index
           )

    create index(:videos, [:library_id, :inserted_at])
    create index(:videos, [:library_id, :upload_date])
    create index(:videos, [:library_id, :title])
    create index(:videos, [:inserted_at])

    create table(:video_categories, primary_key: false) do
      add :video_id, references(:videos, on_delete: :delete_all), primary_key: true
      add :category_id, references(:categories, on_delete: :delete_all), primary_key: true
    end

    create index(:video_categories, [:category_id])

    create table(:subtitles) do
      add :video_id, references(:videos, on_delete: :delete_all), null: false
      add :lang, :string, null: false
      add :auto, :boolean, null: false, default: false
      add :path, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:subtitles, [:video_id])

    create table(:downloads) do
      add :url, :string, null: false
      add :kind, :string, null: false
      add :status, :string, null: false, default: "queued"
      add :library_id, references(:libraries, on_delete: :delete_all)
      add :category_ids, {:array, :integer}, null: false, default: []
      add :video_id, references(:videos, on_delete: :nilify_all)
      add :oban_job_id, :integer
      add :title, :string
      add :progress, :float
      add :speed, :float
      add :eta, :integer
      add :downloaded_bytes, :integer
      add :total_bytes, :integer
      add :error, :text
      add :note, :string
      add :attempt, :integer, null: false, default: 0
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:downloads, [:status])
    create index(:downloads, [:inserted_at])
  end
end
