-- MVP curated song seed, run 2026-10-25
--
-- Context: this app's `songs` table is scoped per-arena (arena_id NOT NULL), and
-- there is currently no song-rotation mechanism (see docs/APP_STATE_AND_ROADMAP.md,
-- item 3 -- still blocked on Sergio's design decision). This seed exists so real
-- song data + audio exists ahead of that decision, not as the final mechanism.
--
-- Source audio: Sergio's personal CD-rip library (F:\Musica\CD's\2012 on his
-- machine), 23 tracks hand-picked for genre/energy variety, approved 2026-10-25.
-- Real durations read via the `music-metadata` npm package (no ffmpeg available
-- in-session; a downloaded static binary was blocked by the auto-mode safety
-- classifier as "code from external" -- correctly, since executing an arbitrary
-- downloaded binary is exactly the kind of thing that classifier should catch).
--
-- Storage: new private bucket `curated-songs` (audio/mpeg only, 50MB/file cap),
-- signed-URL access per the earlier decision in this project (never made public --
-- raw mp3 URLs would otherwise be scrapeable by any participant's phone). Object
-- names are the same UUID as songs.id, stored in songs.audio_storage_path.
--
-- Dedicated arena created for this: id c8d99d16-4dad-498f-88ad-8a21fe15d341,
-- name "MVP Curated Library", host_id NULL (not tied to a specific host).
--
-- Schema change included: `songs.audio_storage_path` did not exist before this --
-- added here since no prior migration file existed for it (none of this schema
-- is tracked anywhere except the live DB -- see docs/APP_STATE_AND_ROADMAP.md).

alter table songs add column if not exists audio_storage_path text;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('curated-songs', 'curated-songs', false, 52428800, array['audio/mpeg'])
on conflict (id) do nothing;

select create_arena('MVP Curated Library', NULL) as arena_id;
-- (returned c8d99d16-4dad-498f-88ad-8a21fe15d341 on the actual run; substitute
-- your own result below if re-running this seed fresh)

insert into songs (id, arena_id, source, spotify_track_id, title, artist, duration_ms, audio_storage_path, status) values
('54f57940-97ce-49a6-9cb8-9edd59d976f0', 'c8d99d16-4dad-498f-88ad-8a21fe15d341', 'upload', '54f57940-97ce-49a6-9cb8-9edd59d976f0', 'Little Talks', 'Of Monsters and Men', 264490, '54f57940-97ce-49a6-9cb8-9edd59d976f0.mp3', 'active'),
('2fbf83f5-dbec-4036-86a6-ead31992b2b2', 'c8d99d16-4dad-498f-88ad-8a21fe15d341', 'upload', '2fbf83f5-dbec-4036-86a6-ead31992b2b2', 'Animus Vox', 'The Glitch Mob', 402129, '2fbf83f5-dbec-4036-86a6-ead31992b2b2.mp3', 'active'),
('5ff81142-6c27-43fd-bd13-8d5c24325dc9', 'c8d99d16-4dad-498f-88ad-8a21fe15d341', 'upload', '5ff81142-6c27-43fd-bd13-8d5c24325dc9', 'Held', 'Holy Other', 367569, '5ff81142-6c27-43fd-bd13-8d5c24325dc9.mp3', 'active'),
('cb2b4a22-d15f-4d2d-a98f-a4fada01025e', 'c8d99d16-4dad-498f-88ad-8a21fe15d341', 'upload', 'cb2b4a22-d15f-4d2d-a98f-a4fada01025e', 'The Animal Pattern', 'Lone', 266397, 'cb2b4a22-d15f-4d2d-a98f-a4fada01025e.mp3', 'active'),
('d624faae-748b-48b5-8b42-58cab59bbfdf', 'c8d99d16-4dad-498f-88ad-8a21fe15d341', 'upload', 'd624faae-748b-48b5-8b42-58cab59bbfdf', 'New France (feat. Zola Jesus)', 'Orbital', 287869, 'd624faae-748b-48b5-8b42-58cab59bbfdf.mp3', 'active'),
('3f5780f5-f00f-434a-aea6-252bb810fa59', 'c8d99d16-4dad-498f-88ad-8a21fe15d341', 'upload', '3f5780f5-f00f-434a-aea6-252bb810fa59', 'Black Heart', 'Calexico', 288967, '3f5780f5-f00f-434a-aea6-252bb810fa59.mp3', 'active'),
('cf3716aa-d78b-4ede-8c81-aa1a97d1dd1f', 'c8d99d16-4dad-498f-88ad-8a21fe15d341', 'upload', 'cf3716aa-d78b-4ede-8c81-aa1a97d1dd1f', 'Friend of the Devil', 'Grateful Dead', 204800, 'cf3716aa-d78b-4ede-8c81-aa1a97d1dd1f.mp3', 'active'),
('e87b1686-3c9b-4d20-b7d6-1ac293204765', 'c8d99d16-4dad-498f-88ad-8a21fe15d341', 'upload', 'e87b1686-3c9b-4d20-b7d6-1ac293204765', 'Run to the Hills', 'Iron Maiden', 233927, 'e87b1686-3c9b-4d20-b7d6-1ac293204765.mp3', 'active'),
('5a1f1ba1-7865-466a-b207-92421aac1035', 'c8d99d16-4dad-498f-88ad-8a21fe15d341', 'upload', '5a1f1ba1-7865-466a-b207-92421aac1035', 'Country House', 'Blur', 237296, '5a1f1ba1-7865-466a-b207-92421aac1035.mp3', 'active'),
('819d6161-5220-40ae-901c-95846f68fd3a', 'c8d99d16-4dad-498f-88ad-8a21fe15d341', 'upload', '819d6161-5220-40ae-901c-95846f68fd3a', 'Mandala', 'Thievery Corporation', 240666, '819d6161-5220-40ae-901c-95846f68fd3a.mp3', 'active'),
('6a5774a6-e0af-4dca-a672-751d81bb4f22', 'c8d99d16-4dad-498f-88ad-8a21fe15d341', 'upload', '6a5774a6-e0af-4dca-a672-751d81bb4f22', 'The Dawn', 'High Tone meets Brain Damage', 425561, '6a5774a6-e0af-4dca-a672-751d81bb4f22.mp3', 'active'),
('367151e3-f287-4ecc-9e9c-b9aa66be1b91', 'c8d99d16-4dad-498f-88ad-8a21fe15d341', 'upload', '367151e3-f287-4ecc-9e9c-b9aa66be1b91', 'Time After Time', 'Chet Baker', 408424, '367151e3-f287-4ecc-9e9c-b9aa66be1b91.mp3', 'active'),
('7cbef33a-ce50-4a89-ad47-a0fc32ad0866', 'c8d99d16-4dad-498f-88ad-8a21fe15d341', 'upload', '7cbef33a-ce50-4a89-ad47-a0fc32ad0866', 'Billie Jean', 'Easy Star All-Stars', 385698, '7cbef33a-ce50-4a89-ad47-a0fc32ad0866.mp3', 'active'),
('592cfa6d-cc33-44ca-ac7a-bf69161a4421', 'c8d99d16-4dad-498f-88ad-8a21fe15d341', 'upload', '592cfa6d-cc33-44ca-ac7a-bf69161a4421', 'Lapis', 'The Cinematic Orchestra', 537861, '592cfa6d-cc33-44ca-ac7a-bf69161a4421.mp3', 'active'),
('5fe7ad4f-7ea9-4bed-bf19-b03a45f4f33b', 'c8d99d16-4dad-498f-88ad-8a21fe15d341', 'upload', '5fe7ad4f-7ea9-4bed-bf19-b03a45f4f33b', 'Chicos, Tenis y Cachucha', 'Nina Dioz', 230243, '5fe7ad4f-7ea9-4bed-bf19-b03a45f4f33b.mp3', 'active'),
('d5b66fbb-3902-4dea-a4e9-e649605f8447', 'c8d99d16-4dad-498f-88ad-8a21fe15d341', 'upload', 'd5b66fbb-3902-4dea-a4e9-e649605f8447', 'Building Steam With a Grain of Salt', 'DJ Shadow', 401424, 'd5b66fbb-3902-4dea-a4e9-e649605f8447.mp3', 'active'),
('3b54bca4-a0b6-4832-bc72-4b64b782eabe', 'c8d99d16-4dad-498f-88ad-8a21fe15d341', 'upload', '3b54bca4-a0b6-4832-bc72-4b64b782eabe', 'Gravity Free', 'AstroPilot', 426214, '3b54bca4-a0b6-4832-bc72-4b64b782eabe.mp3', 'active'),
('32dd4659-7905-4793-8167-36b6dd8569af', 'c8d99d16-4dad-498f-88ad-8a21fe15d341', 'upload', '32dd4659-7905-4793-8167-36b6dd8569af', 'In The Morning', 'Michal Menert', 303099, '32dd4659-7905-4793-8167-36b6dd8569af.mp3', 'active'),
('7a57c7e1-26e7-4dd9-9f83-996b21631146', 'c8d99d16-4dad-498f-88ad-8a21fe15d341', 'upload', '7a57c7e1-26e7-4dd9-9f83-996b21631146', 'I Know The Truth', 'Pretty Lights', 288048, '7a57c7e1-26e7-4dd9-9f83-996b21631146.mp3', 'active'),
('764ab9ec-f772-4f78-8a32-c049b141e292', 'c8d99d16-4dad-498f-88ad-8a21fe15d341', 'upload', '764ab9ec-f772-4f78-8a32-c049b141e292', 'Crunkalicious', 'PANTyRAID', 282540, '764ab9ec-f772-4f78-8a32-c049b141e292.mp3', 'active'),
('4d72ee45-bd44-4051-a228-458b564408cd', 'c8d99d16-4dad-498f-88ad-8a21fe15d341', 'upload', '4d72ee45-bd44-4051-a228-458b564408cd', 'Levitate', 'Paper Diamond', 200046, '4d72ee45-bd44-4051-a228-458b564408cd.mp3', 'active'),
('a07faed9-ffa8-4f68-a431-042e25bb143e', 'c8d99d16-4dad-498f-88ad-8a21fe15d341', 'upload', 'a07faed9-ffa8-4f68-a431-042e25bb143e', 'Passing Storm', 'GMO vs. Dense', 679184, 'a07faed9-ffa8-4f68-a431-042e25bb143e.mp3', 'active'),
('2bb242d6-b184-4f18-a974-ed60ea84d4c6', 'c8d99d16-4dad-498f-88ad-8a21fe15d341', 'upload', '2bb242d6-b184-4f18-a974-ed60ea84d4c6', 'Heartland Feelings', 'Beck', 431073, '2bb242d6-b184-4f18-a974-ed60ea84d4c6.mp3', 'active')
returning id, title;