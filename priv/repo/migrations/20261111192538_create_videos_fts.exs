defmodule Archive.Repo.Migrations.CreateVideosFts do
  use Ecto.Migration

  # Full-text index for live search. The FTS rowid is the video id; rows are
  # maintained from Archive.Videos (subtitle text is read from files, so this is
  # not done with triggers).
  def up do
    execute """
    CREATE VIRTUAL TABLE videos_fts USING fts5(
      title,
      description,
      tags,
      subtitles,
      tokenize = 'unicode61 remove_diacritics 2'
    )
    """
  end

  def down do
    execute "DROP TABLE videos_fts"
  end
end
