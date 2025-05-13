CREATE TABLE posts(
    post_id SERIAL,
    title VARCHAR(255) NOT NULL,
    body_md TEXT NOT NULL,
    slug TEXT NOT NULL UNIQUE,
    summary TEXT,
    search_vector tsvector GENERATED ALWAYS AS (
        setweight(to_tsvector('english', coalesce(title, '')), 'A')   ||
        setweight(to_tsvector('english', coalesce(summary, '')), 'B') ||
        setweight(to_tsvector('english', coalesce(body_md, '')), 'C') 
    ) STORED,
    is_public BOOLEAN DEFAULT FALSE,
    is_published BOOLEAN DEFAULT FALSE,
    published_at TIMESTAMPTZ,
    CHECK (
        (published_at IS NOT NULL)
        OR 
        (is_published = FALSE)
    ),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (post_id)
);
CREATE INDEX idx_posts_published_at ON posts (published_at) WHERE (is_public);
CREATE INDEX idx_posts_search ON posts USING GIN (search_vector);

CREATE TABLE post_versions(
    post_id INTEGER,
    version INTEGER NOT NULL,
    title VARCHAR(255) NOT NULL,
    body_md TEXT NOT NULL,
    slug TEXT NOT NULL,
    summary TEXT,
    search_vector tsvector GENERATED ALWAYS AS (
        setweight(to_tsvector('english', coalesce(title, '')), 'A')   ||
        setweight(to_tsvector('english', coalesce(summary, '')), 'B') ||
        setweight(to_tsvector('english', coalesce(body_md, '')), 'C') 
    ) STORED,
    is_public BOOLEAN NOT NULL,
    is_published BOOLEAN NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    archived_at TIMESTAMPTZ, -- when each published version was archived
    CHECK (
        (is_published = FALSE AND archived_at IS NULL)
        OR
        (is_published = TRUE)
    ), 
    FOREIGN KEY (post_id) REFERENCES posts (post_id)
        ON DELETE CASCADE,
    PRIMARY KEY (post_id, version)
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_post_versions_unique_active_published -- Each post can only have one active published version
    ON post_versions (post_id) 
    WHERE is_published = TRUE AND archived_at IS NULL;
CREATE INDEX idx_post_versions_visible_by_created_at_desc ON post_versions (post_id, created_at DESC) WHERE (is_published AND is_public);
CREATE INDEX idx_post_versions_search ON post_versions USING GIN (search_vector);

CREATE TABLE tags(
    tag_id SERIAL,
    tag TEXT NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tag_id)
);

CREATE TABLE post_tags(
    post_id INTEGER NOT NULL,
    tag_id INTEGER NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (post_id) REFERENCES posts (post_id)
        ON DELETE CASCADE,
    FOREIGN KEY (tag_id) REFERENCES tags (tag_id)
        ON DELETE CASCADE,
    PRIMARY KEY (post_id, tag_id)
);
CREATE INDEX idx_post_tags_tag ON post_tags (tag_id);

CREATE TABLE media(
    media_id SERIAL,
    file_url TEXT NOT NULL UNIQUE,
    alt_text TEXT,
    mime_type TEXT,
    size_bytes INTEGER,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (media_id)
);
CREATE INDEX idx_media_file_url ON media (file_url);

-- Triggers --

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER a_trg_set_updated_at_posts 
BEFORE UPDATE ON posts
FOR EACH ROW
WHEN (OLD IS DISTINCT FROM NEW)
EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_set_updated_at_tags
BEFORE UPDATE ON tags
FOR EACH ROW
WHEN (OLD IS DISTINCT FROM NEW)
EXECUTE FUNCTION set_updated_at();

-- Creates a new entry in the `post_versions` table 
-- Will be called by triggers on the `posts` table 
CREATE OR REPLACE FUNCTION record_post_version()
RETURNS TRIGGER AS $$
DECLARE
    new_version_number INTEGER;
BEGIN
    -- Determine the new version number
    IF TG_OP = 'INSERT' THEN
        new_version_number := 1; -- New post, so first version
    ELSIF TG_OP = 'UPDATE' THEN
        SELECT COALESCE(MAX(version), 0) + 1
        INTO new_version_number
        FROM post_versions
        WHERE post_id = NEW.post_id;
    END IF;

    -- Insert the new version into `post_versions`
    INSERT INTO post_versions(
        post_id,
        version,
        title,
        body_md,
        slug,
        summary,
        is_public,
        is_published,
        created_at -- Set to match original `post` created_at or updated_at
    ) VALUES (
        NEW.post_id,
        new_version_number,
        NEW.title,
        NEW.body_md,
        NEW.slug,
        NEW.summary,
        NEW.is_public,
        NEW.is_published,
        NEW.updated_at -- Same as created_at for new posts
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- When a new post is inserted into `posts`, add its first version in `post_versions`
CREATE TRIGGER trg_posts_after_insert_create_version
AFTER INSERT ON posts
FOR EACH ROW
EXECUTE FUNCTION record_post_version();

-- When a post is updated in `posts` add a new version into `post_versions`
CREATE TRIGGER trg_posts_after_update_create_version
AFTER UPDATE ON posts
FOR EACH ROW
WHERE (
    OLD.title IS DISTINCT FROM NEW.title OR
    OLD.body_md IS DISTINCT FROM NEW.body_md OR
    OLD.slug IS DISTINCT FROM NEW.slug OR
    OLD.summary IS DISTINCT FROM NEW.summary OR
    OLD.is_public IS DISTINCT FROM NEW.is_public OR
    OLD.is_published IS DISTINCT FROM NEW.is_published 
)
EXECUTE FUNCTION record_post_version();

-- Archive old posts when a new published version is added to `post_versions`
CREATE OR REPLACE FUNCTION archive_old_post_versions()
RETURNS TRIGGER AS $$
BEGIN
    NEW.archived_at := NULL; -- new post so has not been archived

    -- Archive most recent published post
    UPDATE post_versions
    SET archived_at = now()
    WHERE post_id = NEW.post_id
        AND is_published = TRUE
        AND archived_at IS NULL;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Archive old post trigger
CREATE TRIGGER trg_post_versions_insert_published
BEFORE INSERT ON post_versions
FOR EACH ROW
WHERE (NEW.is_published = TRUE)
EXECUTE FUNCTION archive_old_post_versions();

-- Sets the `published_at` timestamp on the `posts` table
CREATE OR REPLACE FUNCTION set_first_published_at()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.is_published = TRUE 
        AND (TG_OP = 'INSERT' OR OLD.is_published = FALSE) 
        AND NEW.published_at IS NULL 
    THEN
        NEW.published_at := NEW.updated_at;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Sets the `published_at` field when publishing a post for the first time
CREATE TRIGGER trg_set_published_at_on_posts
BEFORE INSERT OR UPDATE OF is_published ON posts
FOR EACH ROW
EXECUTE FUNCTION set_first_published_at();
