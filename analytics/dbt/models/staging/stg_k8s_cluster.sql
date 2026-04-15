{{ config(
    tags = ['staging', 'k8s']
) }}
-- stg_k8s_cluster
-- Normalises raw Kubernetes NodeList JSON into typed, flat rows.
--
-- Source shape (one file per collection run):
--   kind      "NodeList"
--   items     list of node objects; one node per cluster
--     name                  string
--     labels                struct of label key→value strings
--     conditions            list of condition structs (type, status, timestamps)
--     allocatable           struct of resource strings (cpu, memory, ephemeral-storage, pods)
--     capacity              struct of resource strings
--     node_info             struct (architecture, kernel/kubelet/os/runtime versions)
WITH raw AS (

    SELECT
        *
    FROM
        {{ source('source_k8s_cluster', 'snapshots') }}
),

unpacked AS (

    SELECT
        filename,
        try_strptime(
            REGEXP_REPLACE(
                REGEXP_REPLACE(REGEXP_REPLACE(filename, '^.*/', ''), '\.json$', ''),
                '-(\d{2})-(\d{2})$',
                '+\1:\2'
            ),
            '%Y-%m-%dT%H-%M-%S.%f%z'
        ) AS collected_at_filename,
        list_extract(items, 1) AS node
    FROM
        raw
),

temp AS (

    SELECT
        filename,
        collected_at_filename,

        -- Identity
        node.name :: VARCHAR AS cluster_name,
        node.labels."kubernetes.io/hostname" :: VARCHAR AS hostname,

        -- Labels
        node.labels."beta.kubernetes.io/arch" :: VARCHAR AS beta_cluster_architecture,
        node.labels."beta.kubernetes.io/instance-type" :: VARCHAR AS beta_instance_type,
        node.labels."beta.kubernetes.io/os" :: VARCHAR AS beta_os,
        node.labels."kubernetes.io/arch" :: VARCHAR AS cluster_architecture,
        node.labels."kubernetes.io/os" :: VARCHAR AS os,
        node.labels."node-role.kubernetes.io/control-plane" :: VARCHAR AS node_control_plane,
        node.labels."node-role.kubernetes.io/etcd" :: VARCHAR AS node_etcd,
        node.labels."node.kubernetes.io/instance-type" :: VARCHAR AS node_instance_type,

        -- Conditions: filter list by type, extract status string
        list_filter(node.conditions, x -> x.type = 'Ready')[1].status :: VARCHAR AS condition_ready_status,
        list_filter(node.conditions, x -> x.type = 'Ready')[1].lastHeartbeatTime :: TIMESTAMPTZ AS condition_ready_heartbeat_at,
        list_filter(node.conditions, x -> x.type = 'MemoryPressure')[1].status :: VARCHAR AS condition_memory_pressure_status,
        list_filter(node.conditions, x -> x.type = 'DiskPressure')[1].status :: VARCHAR AS condition_disk_pressure_status,
        list_filter(node.conditions, x -> x.type = 'PIDPressure')[1].status :: VARCHAR AS condition_pid_pressure_status,
        list_filter(node.conditions, x -> x.type = 'EtcdIsVoter')[1].status :: VARCHAR AS condition_etcd_is_voter_status,

        -- Allocatable resources
        -- cpu / pods are plain integers; memory and ephemeral-storage carry a 'Ki' suffix
        node.allocatable.cpu :: INTEGER AS allocatable_cpu,
        node.allocatable.pods :: INTEGER AS allocatable_pods,
        TRY_CAST(REPLACE(node.allocatable.memory, 'Ki', '') AS BIGINT) AS allocatable_memory_ki,
        TRY_CAST(
            REPLACE(struct_extract(node.allocatable, 'ephemeral-storage'), 'Ki', '') AS BIGINT
        ) AS allocatable_ephemeral_storage_ki,

        -- Capacity resources (same shape as allocatable)
        node.capacity.cpu :: INTEGER AS capacity_cpu,
        node.capacity.pods :: INTEGER AS capacity_pods,
        TRY_CAST(REPLACE(node.capacity.memory, 'Ki', '') AS BIGINT) AS capacity_memory_ki,
        TRY_CAST(
            REPLACE(struct_extract(node.capacity, 'ephemeral-storage'), 'Ki', '') AS BIGINT
        ) AS capacity_ephemeral_storage_ki,

        -- Node info
        node.node_info.architecture :: VARCHAR AS node_architecture,
        node.node_info.kernel_version :: VARCHAR AS kernel_version,
        node.node_info.kubelet_version :: VARCHAR AS kubelet_version,
        node.node_info.os_image :: VARCHAR AS os_image,
        node.node_info.container_runtime_version :: VARCHAR AS container_runtime_version,

    FROM
        unpacked
)

SELECT
    {{ dbt_utils.generate_surrogate_key(['filename']) }} AS snapshot_id,
    collected_at_filename,
    cluster_name,
    hostname,
    -- Architecture / OS (from labels; node_architecture from node_info is redundant but kept for cross-check)
    beta_cluster_architecture,
    beta_instance_type,
    beta_os,
    cluster_architecture,
    os,
    node_architecture,
    node_instance_type,
    kernel_version,
    kubelet_version,
    os_image,
    container_runtime_version,
    -- Node roles (label presence = role is active)
    COALESCE(node_control_plane = 'true', FALSE) AS control_plane_enabled,
    COALESCE(node_etcd = 'true', FALSE) AS node_etcd_enabled,
    -- Conditions mapped to booleans; True status = condition is active
    -- Ready = True means healthy; pressure conditions = True means problem
    COALESCE(condition_ready_status = 'True', FALSE) AS node_ready,
    condition_ready_heartbeat_at,
    COALESCE(condition_memory_pressure_status = 'True', FALSE) AS memory_pressure,
    COALESCE(condition_disk_pressure_status = 'True', FALSE) AS disk_pressure,
    COALESCE(condition_pid_pressure_status = 'True', FALSE) AS pid_pressure,
    COALESCE(condition_etcd_is_voter_status = 'True', FALSE) AS etcd_is_voter,
    -- Allocatable / capacity in Ki (keep unit consistent; memory always in Ki, ephemeral-storage normalised to Ki)
    allocatable_cpu,
    allocatable_pods,
    allocatable_memory_ki,
    allocatable_ephemeral_storage_ki,
    capacity_cpu,
    capacity_pods,
    capacity_memory_ki,
    capacity_ephemeral_storage_ki,
FROM
    temp
