# patch-postgresql-k8s-no-k8s-api.star
#
# Patches the postgresql-k8s charm to remove all direct Kubernetes API calls
# made via the lightkube library.  Every k8s API call becomes a no-op or
# returns a safe default so the charm can operate without cluster-admin
# access (or in environments where the k8s API is unavailable).
#
# Files patched:
#   src/charm.py                     – 9 k8s-using functions
#   src/backups.py                   – restore-action DCS cleanup
#   src/relations/async_replication.py – standby-cluster DCS cleanup
#
# Functional impact:
#   * _create_services / _patch_pod_labels   – primary/replica Services and
#     Pod labels are not created; operators must manage these externally.
#   * _check_headless_service               – headless-service existence is
#     no longer verified; charm continues regardless.
#   * fix_leader_annotation                 – leader annotation is not patched
#     via k8s; Patroni handles this itself on startup.
#   * _cleanup_old_cluster_resources        – stale Patroni DCS objects are
#     not deleted on first-deployment; harmless if cluster is freshly created.
#   * _on_stop                              – ownerReference patching on scale-
#     down is skipped; resources may linger until manually removed.
#   * get_node_cpu_cores / get_node_allocable_memory / get_resources_limits
#     – PostgreSQL tuning uses hard-coded defaults (4 cores, 4 GiB) instead
#     of querying Node/Pod resource data.  Tune via charm config if needed.
#   * backups _on_restore_action DCS delete – the pre-restore Patroni endpoint
#     removal is skipped; Patroni typically handles this itself.
#   * async_replication _remove_previous_cluster_information – old DCS objects
#     are not deleted when setting up as a standby cluster.

if "postgresql-k8s" not in charm_url:
    log("skipping: charm_url does not contain 'postgresql-k8s'")
else:
    log("applying no-k8s-api patch to " + charm_url)

    # ──────────────────────────────────────────────────────────────────────────
    # src/charm.py
    # ──────────────────────────────────────────────────────────────────────────
    _path = "src/charm.py"
    if charm_exists(_path):
        _content = charm_read(_path).decode("utf-8")
        _original = _content

        # 1. fix_leader_annotation
        #    Skip reading/patching Patroni's leader Endpoints object; always
        #    report success so callers continue normally.
        _content = _content.replace(
            """        client = Client()
        try:
            endpoint = client.get(Endpoints, name=self.cluster_name, namespace=self._namespace)
            if (
                endpoint.metadata
                and endpoint.metadata.annotations is not None
                and "leader" not in endpoint.metadata.annotations
            ):
                patch = {
                    "metadata": {
                        "annotations": {"leader": self._unit_name_to_pod_name(self._unit)}
                    }
                }
                client.patch(
                    Endpoints, name=self.cluster_name, namespace=self._namespace, obj=patch
                )
                self.app_peer_data.pop("cluster_initialised", None)
                logger.info("Fixed missing leader annotation")
        except ApiError as e:
            if e.status.code == 403:
                self.on_deployed_without_trust()
                return False
            # Ignore the error only when the resource doesn't exist.
            if e.status.code != 404:
                raise e
        return True""",
            """        return True""",
            1,
        )

        # 2. _patch_pod_labels
        #    Skip patching Pod labels (used for Service selectors).
        _content = _content.replace(
            """        client = Client()
        patch = {
            "metadata": {"labels": {"application": "patroni", "cluster-name": self.cluster_name}}
        }
        client.patch(
            Pod,
            name=self._unit_name_to_pod_name(member),
            namespace=self._namespace,
            obj=patch,
        )""",
            """        pass  # k8s API removed""",
            1,
        )

        # 3. _check_headless_service
        #    Skip checking for the headless Service; continue without error.
        _content = _content.replace(
            """        client = Client()
        svc_name = f"{self.app.name}-endpoints"
        try:
            client.get(Service, name=svc_name, namespace=self.model.name)
        except ApiError as e:
            if e.status.code == 404:
                logger.error(
                    "error: headless service %r is missing - recreate it and run "
                    "'juju resolve' on each unit. See "
                    "https://github.com/canonical/postgresql-k8s-operator/issues/392",
                    svc_name,
                )
                raise RuntimeError from None
            raise""",
            """        pass  # k8s API removed""",
            1,
        )

        # 4. _create_services
        #    Skip creating primary/replicas Services.
        _content = _content.replace(
            """        client = Client()

        pod0 = client.get(
            res=Pod,
            name=f"{self.app.name}-0",
            namespace=self.model.name,
        )
        if not pod0 or not pod0.metadata:
            raise Exception("Unable to get pod0")

        services = {
            "primary": "primary",
            "replicas": "replica",
        }
        for service_name_suffix, role_selector in services.items():
            name = f"{self._name}-{service_name_suffix}"
            service = Service(
                metadata=ObjectMeta(
                    name=name,
                    namespace=self.model.name,
                    ownerReferences=pod0.metadata.ownerReferences,
                    labels={
                        "app.kubernetes.io/name": self.app.name,
                    },
                ),
                spec=ServiceSpec(
                    ports=[
                        ServicePort(
                            name="api",
                            port=8008,
                            targetPort=8008,
                        ),
                        ServicePort(
                            name="database",
                            port=5432,
                            targetPort=5432,
                        ),
                    ],
                    selector={
                        "app.kubernetes.io/name": self.app.name,
                        "cluster-name": f"patroni-{self.app.name}",
                        "role": role_selector,
                    },
                ),
            )
            client.apply(
                obj=service,  # type: ignore
                name=name,
                namespace=self.model.name,
                force=True,
                field_manager=self.model.app.name,
            )""",
            """        pass  # k8s API removed""",
            1,
        )

        # 5. _cleanup_old_cluster_resources
        #    Skip deleting stale Patroni DCS Service/Endpoints objects.
        _content = _content.replace(
            """        client = Client()
        for kind, suffix in itertools.product([Service, Endpoints], ["", "-config", "-sync"]):
            try:
                client.delete(
                    res=kind,
                    name=f"{self.cluster_name}{suffix}",
                    namespace=self._namespace,
                )
                logger.info(f"deleted {kind.__name__}/{self.cluster_name}{suffix}")
            except ApiError as e:
                if e.status.code == 403:
                    self.on_deployed_without_trust()
                    return
                # Ignore the error only when the resource doesn't exist.
                if e.status.code != 404:
                    raise e""",
            """        pass  # k8s API removed""",
            1,
        )

        # 6. _on_stop – k8s ownerReference patching section
        #    Skip the entire block that patches Service/Endpoints ownerReferences
        #    when scaling down to zero.  The unit_peer_data.clear() at the top
        #    of the handler is preserved.
        _content = _content.replace(
            """

        # Patch the services to remove them when the StatefulSet is deleted
        # (i.e. application is removed).
        try:
            client = Client(field_manager=self.model.app.name)

            pod0 = client.get(
                res=Pod,
                name=f"{self.app.name}-0",
                namespace=self.model.name,
            )
        except ApiError:
            # Only log the exception.
            logger.exception("failed to get first pod info")
            return

        if not pod0 or not pod0.metadata:
            logger.error("Failed to get pod0 details")
            return

        try:
            # Get the k8s resources created by the charm and Patroni.
            resources_to_patch = []
            for kind in [Endpoints, Service]:
                # Get resources with Juju's created-by label
                resources_to_patch.extend(
                    client.list(
                        kind,
                        namespace=self._namespace,
                        labels={"app.juju.is/created-by": f"{self._name}"},
                    )
                )

                # Since Juju 3.6.13 (commit aa38cff0b1), the mutating webhook no longer
                # processes Endpoints - they were removed from the webhook's resource allowlist.
                # Patroni creates its own Endpoints with these labels:
                # - application: patroni
                # - cluster-name: patroni-{application}
                # These resources never get Juju labels, so we must query for them separately.
                resources_to_patch.extend(
                    client.list(
                        kind,
                        namespace=self._namespace,
                        labels={
                            "application": "patroni",
                            "cluster-name": f"patroni-{self._name}",
                        },
                    )
                )
        except ApiError:
            # Only log the exception.
            logger.exception("failed to get the k8s resources created by the charm and Patroni")
            return

        for resource in resources_to_patch:
            # Ignore resources created by Juju or the charm
            # (which are already patched).
            if (
                not resource.metadata
                or not resource.metadata.name
                or not resource.metadata.namespace
                or (
                    type(resource) is Service
                    and resource.metadata.name
                    in [
                        self._name,
                        f"{self._name}-endpoints",
                        f"{self._name}-primary",
                        f"{self._name}-replicas",
                    ]
                )
                or resource.metadata.ownerReferences == pod0.metadata.ownerReferences
            ):
                continue
            # Patch the resource.
            try:
                resource.metadata.ownerReferences = pod0.metadata.ownerReferences
                resource.metadata.managedFields = None
                client.apply(
                    obj=resource,  # type: ignore
                    name=resource.metadata.name,
                    namespace=resource.metadata.namespace,
                    force=True,
                )
            except ApiError:
                # Only log the exception.
                logger.exception(
                    f"failed to patch k8s {type(resource).__name__} {resource.metadata.name}"
                )
""",
            "",
            1,
        )

        # 7. _get_node_name_for_pod
        #    Return an empty string; callers (get_node_*) are also replaced.
        _content = _content.replace(
            """        client = Client()
        pod = client.get(
            Pod, name=self._unit_name_to_pod_name(self.unit.name), namespace=self._namespace
        )
        if pod.spec and pod.spec.nodeName:
            return pod.spec.nodeName
        else:
            raise Exception("Pod doesn't exist")""",
            """        return ""  # k8s API removed""",
            1,
        )

        # 8. get_resources_limits
        #    Return empty dict (no container resource limits known).
        _content = _content.replace(
            """        client = Client()
        pod = client.get(
            Pod, self._unit_name_to_pod_name(self.unit.name), namespace=self._namespace
        )

        if pod.spec:
            for container in pod.spec.containers:
                if container.name == container_name and container.resources:
                    return container.resources.limits or {}
        return {}""",
            """        return {}  # k8s API removed""",
            1,
        )

        # 9. get_node_allocable_memory
        #    Return a 4 GiB default.  Tune via charm config (profile_limit_memory)
        #    or PostgreSQL parameters if the actual node has less memory.
        _content = _content.replace(
            """        client = Client()
        node = client.get(Node, name=self._get_node_name_for_pod(), namespace=self._namespace)  # type: ignore
        return any_memory_to_bytes(node.status.allocatable["memory"])""",
            """        return 4 * 1024 * 1024 * 1024  # k8s API removed; 4 GiB default""",
            1,
        )

        # 10. get_node_cpu_cores
        #     Return a 4-core default.
        _content = _content.replace(
            """        client = Client()
        node = client.get(Node, name=self._get_node_name_for_pod(), namespace=self._namespace)  # type: ignore
        return any_cpu_to_cores(node.status.allocatable["cpu"])""",
            """        return 4  # k8s API removed; 4-core default""",
            1,
        )

        if _content != _original:
            charm_write(_path, _content)
            log("patched " + _path)
        else:
            log("WARNING: no changes made to " + _path + " – version mismatch?")

    # ──────────────────────────────────────────────────────────────────────────
    # src/backups.py
    # ──────────────────────────────────────────────────────────────────────────
    _path = "src/backups.py"
    if charm_exists(_path):
        _content = charm_read(_path).decode("utf-8")
        _original = _content

        # _on_restore_action – skip deleting Patroni DCS Endpoints before restore.
        # Patroni will re-initialise the cluster from the backup regardless.
        _content = _content.replace(
            """        logger.info("Removing previous cluster information")
        try:
            client = Client()
            client.delete(
                Endpoints,
                name=f"patroni-{self.charm._name}",
                namespace=self.charm._namespace,
            )
            client.delete(
                Endpoints,
                name=f"patroni-{self.charm._name}-config",
                namespace=self.charm._namespace,
            )
        except ApiError as e:
            # If previous PITR restore was unsuccessful, there are no such endpoints.
            if not self.charm.is_cluster_restoring_to_time:
                error_message = f"Failed to remove previous cluster information with error: {e!s}"
                logger.error(f"Restore failed: {error_message}")
                event.fail(error_message)
                self._restart_database()
                return""",
            """        logger.info("Removing previous cluster information (k8s API removed - no-op)")""",
            1,
        )

        if _content != _original:
            charm_write(_path, _content)
            log("patched " + _path)
        else:
            log("WARNING: no changes made to " + _path + " – version mismatch?")

    # ──────────────────────────────────────────────────────────────────────────
    # src/relations/async_replication.py
    # ──────────────────────────────────────────────────────────────────────────
    _path = "src/relations/async_replication.py"
    if charm_exists(_path):
        _content = charm_read(_path).decode("utf-8")
        _original = _content

        # _remove_previous_cluster_information – skip deleting old Patroni DCS
        # Service/Endpoints objects when switching to standby-cluster mode.
        _content = _content.replace(
            """        client = Client()
        for values in itertools.product(
            [Endpoints, Service],
            [
                f"patroni-{self.charm._name}",
                f"patroni-{self.charm._name}-config",
                f"patroni-{self.charm._name}-sync",
            ],
        ):
            try:
                client.delete(
                    values[0],
                    name=values[1],
                    namespace=self.charm._namespace,
                )
                logger.debug(f"Deleted {values[0]} {values[1]}")
            except ApiError as e:
                # Ignore the error only when the resource doesn't exist.
                if e.status.code != 404:
                    raise e
                logger.debug(f"{values[0]} {values[1]} not found")""",
            """        pass  # k8s API removed""",
            1,
        )

        if _content != _original:
            charm_write(_path, _content)
            log("patched " + _path)
        else:
            log("WARNING: no changes made to " + _path + " – version mismatch?")
