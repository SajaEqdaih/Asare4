-- عالسريع! — SQL starting point for a future Supabase backend.
-- IMPORTANT: The included web prototype is LOCAL DEMO ONLY and does not connect to this schema.
-- Do not expose service_role keys, allow anonymous writes to owner tables,
-- or treat frontend role toggles as authentication.
create extension if not exists pgcrypto;

create table if not exists public.staff_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  role text not null check (role in ('owner','staff')),
  created_at timestamptz default now() not null
);

create or replace function public.is_restaurant_staff()
returns boolean language sql stable security definer set search_path = public
as $$
 select exists (select 1 from public.staff_profiles where user_id=auth.uid() and role in ('owner','staff'));
$$;
create or replace function public.is_restaurant_owner()
returns boolean language sql stable security definer set search_path = public
as $$
 select exists (select 1 from public.staff_profiles where user_id=auth.uid() and role='owner');
$$;

create table if not exists public.products (
  id bigint generated always as identity primary key,
  name text not null,
  category text not null check(category in ('meals','breakfast','coffee','drinks','sweets')),
  description text not null default '',
  price numeric(12,2) not null check (price >= 0),
  image_url text,
  badge text not null default '',
  available boolean not null default true,
  hidden boolean not null default false,
  featured boolean not null default false,
  addon_options jsonb not null default '[]'::jsonb,
  size_options jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);
create table if not exists public.combos (
  id bigint generated always as identity primary key,
  name text not null,
  description text not null default '',
  price numeric(12,2) not null check(price >= 0),
  icon text not null default '🍱',
  active boolean not null default true
);
create table if not exists public.combo_products (
  combo_id bigint not null references public.combos(id) on delete cascade,
  product_id bigint not null references public.products(id),
  quantity integer not null default 1 check(quantity > 0),
  primary key(combo_id,product_id)
);
create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  order_reference text unique not null,
  customer_name text not null,
  customer_phone text not null,
  fulfillment text not null check(fulfillment in ('dine','takeaway','delivery')),
  table_number integer,
  delivery_address text,
  note text,
  status text not null default 'draft' check(status in ('draft','new','preparing','ready','delivered','cancelled')),
  subtotal numeric(12,2) not null check(subtotal >= 0),
  delivery_fee numeric(12,2) not null default 0 check(delivery_fee >= 0),
  total numeric(12,2) not null check(total >= 0),
  confirmed_by uuid references auth.users(id),
  confirmed_at timestamptz,
  created_at timestamptz not null default now()
);
create table if not exists public.order_items (
  id bigint generated always as identity primary key,
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id bigint references public.products(id),
  combo_id bigint references public.combos(id),
  product_name_snapshot text not null,
  unit_price_snapshot numeric(12,2) not null check(unit_price_snapshot >= 0),
  quantity integer not null check(quantity > 0),
  selected_addons jsonb not null default '[]'::jsonb,
  selected_size text,
  kitchen_note text
);
create table if not exists public.restaurant_settings (
  singleton integer primary key default 1 check(singleton=1),
  name text not null default 'عالسريع!',
  whatsapp_number text not null,
  address text,
  opening_hours text,
  delivery_fee numeric(12,2) not null default 0,
  ordering_open boolean not null default true,
  dine boolean not null default true,
  takeaway boolean not null default true,
  delivery boolean not null default false,
  table_count integer not null default 6,
  updated_at timestamptz not null default now()
);
create table if not exists public.order_status_events (
  id bigint generated always as identity primary key,
  order_id uuid not null references public.orders(id) on delete cascade,
  previous_status text,
  new_status text not null,
  actor_user_id uuid references auth.users(id),
  changed_at timestamptz not null default now(),
  reason text
);

alter table public.staff_profiles enable row level security;
alter table public.products enable row level security;
alter table public.combos enable row level security;
alter table public.combo_products enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.restaurant_settings enable row level security;
alter table public.order_status_events enable row level security;

create policy staff_profiles_self_read on public.staff_profiles for select to authenticated
using (user_id=auth.uid() or public.is_restaurant_owner());
create policy staff_profiles_owner_manage on public.staff_profiles for all to authenticated
using(public.is_restaurant_owner()) with check(public.is_restaurant_owner());

create policy public_products_read on public.products for select to anon, authenticated
using((available=true and hidden=false) or public.is_restaurant_staff());
create policy owner_products_modify on public.products for all to authenticated
using(public.is_restaurant_owner()) with check(public.is_restaurant_owner());

create policy public_combos_read on public.combos for select to anon, authenticated
using(active=true or public.is_restaurant_staff());
create policy owner_combos_modify on public.combos for all to authenticated
using(public.is_restaurant_owner()) with check(public.is_restaurant_owner());
create policy public_combo_items_read on public.combo_products for select to anon, authenticated
using(exists (select 1 from public.combos c where c.id=combo_id and c.active=true) or public.is_restaurant_staff());
create policy owner_combo_items_modify on public.combo_products for all to authenticated
using(public.is_restaurant_owner()) with check(public.is_restaurant_owner());

create policy staff_orders_read on public.orders for select to authenticated using(public.is_restaurant_staff());
create policy staff_orders_update on public.orders for update to authenticated
using(public.is_restaurant_staff()) with check(public.is_restaurant_staff());
create policy staff_items_read on public.order_items for select to authenticated using(public.is_restaurant_staff());
create policy staff_settings_read on public.restaurant_settings for select to authenticated using(public.is_restaurant_staff());
create policy owner_settings_modify on public.restaurant_settings for all to authenticated
using(public.is_restaurant_owner()) with check(public.is_restaurant_owner());
create policy staff_events_read on public.order_status_events for select to authenticated using(public.is_restaurant_staff());

-- No anon insert/update policies on orders or order_items on purpose.
-- Use a server-side / edge-function endpoint with rate limiting, server-side price
-- recalculation and validation to create orders. Treat opened WhatsApp chats as UNVERIFIED.
-- Bootstrap the first owner via Supabase Auth and an admin SQL insert into staff_profiles.
-- Separate multi-tenant restaurant_id keys if you later support multiple restaurants.
