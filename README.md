# Discourse Etiquette plugin
This plugin flags toxic post by Google's Perspective API.

## Installation

Follow the directions at [Install a Plugin](https://meta.discourse.org/t/install-a-plugin/19157) using https://github.com/fantasticfears/discourse-etiquette.git as the repository URL.

## Authors

Erick Guan

## License

GNU GPL v2

## Data Explorer Queries

If you choose standard mode, use `post_etiquette_toxicity`. Otherwise, replace them to `post_etiquette_severe_toxicity`.

Most toxic categories:

```sql
SELECT * FROM post_custom_fields p JOIN posts ON posts.id = p.post_id
```

Most toxic users:

```sql
SELECT * FROM post_custom_fields p JOIN posts ON posts.id = p.post_id
```

Most toxic posts:

```sql
SELECT * FROM post_custom_fields p JOIN posts ON posts.id = p.post_id WHERE p.name = 'post_etiquette_toxicity';
```

Most toxic posts today:

```sql
SELECT * FROM post_custom_fields p JOIN posts ON posts.id = p.post_id
```
