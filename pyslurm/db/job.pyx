#########################################################################
# job.pyx - pyslurm slurmdbd job api
#########################################################################
# Copyright (C) 2023 Toni Harzendorf <toni.harzendorf@gmail.com>
#
# This file is part of PySlurm
#
# PySlurm is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.

# PySlurm is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with PySlurm; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
#
# cython: c_string_type=unicode, c_string_encoding=default
# cython: language_level=3

from os import WIFSIGNALED, WIFEXITED, WTERMSIG, WEXITSTATUS
from typing import Union
from pyslurm.core.error import RPCError
from pyslurm.core import slurmctld
from typing import Any
from pyslurm.utils.uint import *
from pyslurm.utils.ctime import (
    date_to_timestamp,
    timestr_to_mins,
    _raw_time,
)
from pyslurm.utils.helpers import (
    gid_to_name,
    group_to_gid,
    user_to_uid,
    uid_to_name,
    nodelist_to_range_str,
    instance_to_dict,
)


cdef class JobSearchFilter:

    def __cinit__(self):
        self.ptr = NULL

    def __init__(self, **kwargs):
        for k, v in kwargs.items():
            setattr(self, k, v)

    def __dealloc__(self):
        self._dealloc()

    def _dealloc(self):
        slurmdb_destroy_job_cond(self.ptr)
        self.ptr = NULL

    def _alloc(self):
        self._dealloc()
        self.ptr = <slurmdb_job_cond_t*>try_xmalloc(sizeof(slurmdb_job_cond_t))
        if not self.ptr:
            raise MemoryError("xmalloc failed for slurmdb_job_cond_t")
        
        self.ptr.db_flags = slurm.SLURMDB_JOB_FLAG_NOTSET
        self.ptr.flags |= slurm.JOBCOND_FLAG_NO_TRUNC

    def _parse_qos(self):
        if not self.qos:
            return None

        qos_id_list = []
        qos = QualitiesOfService.load()
        for q in self.qos:
            if isinstance(q, int):
                qos_id_list.append(q)
            elif q in qos:
                qos_id_list.append(str(qos[q].id))
            else:
                raise ValueError(f"QoS {q} does not exist")

        return qos_id_list

    def _parse_groups(self):
        if not self.groups:
            return None

        gid_list = []
        for group in self.groups:
            if isinstance(group, int):
                gid_list.append(group)
            else:
                gid_list.append(group_to_gid(group))

        return gid_list

    def _parse_users(self):
        if not self.users:
            return None

        uid_list = []
        for user in self.users:
            if not isinstance(user, list):
                uid_list.append(int(user))
            elif user:
                uid_list.append(user_to_uid(user))

        return uid_list

    def _parse_clusters(self):
        if not self.clusters:
            # Get the local cluster name
            # This is a requirement for some other parameters to function
            # correctly, like self.nodelist
            slurm_conf = slurmctld.Config.load()
            return [slurm_conf.cluster]
        elif self.clusters == "all":
            return None
        else:
            return self.clusters

    def _parse_state(self):
        # TODO: implement
        return None
            
    def _create(self):
        self._alloc()
        cdef:
            slurmdb_job_cond_t *ptr = self.ptr
            slurm_selected_step_t *selected_step

        ptr.usage_start = date_to_timestamp(self.start_time)  
        ptr.usage_end = date_to_timestamp(self.end_time)  
        slurmdb_job_cond_def_start_end(ptr)
        ptr.cpus_min = u32(self.cpus, on_noval=0)
        ptr.cpus_max = u32(self.max_cpus, on_noval=0)
        ptr.nodes_min = u32(self.nodes, on_noval=0)
        ptr.nodes_max = u32(self.max_nodes, on_noval=0)
        ptr.timelimit_min = u32(timestr_to_mins(self.timelimit), on_noval=0)
        ptr.timelimit_max = u32(timestr_to_mins(self.max_timelimit),
                                on_noval=0)
        make_char_list(&ptr.acct_list, self.accounts)
        make_char_list(&ptr.associd_list, self.association_ids)
        make_char_list(&ptr.cluster_list, self._parse_clusters())
        make_char_list(&ptr.constraint_list, self.constraints)
        make_char_list(&ptr.jobname_list, self.names)
        make_char_list(&ptr.groupid_list, self._parse_groups())
        make_char_list(&ptr.userid_list, self._parse_users())
        make_char_list(&ptr.wckey_list, self.wckeys)
        make_char_list(&ptr.partition_list, self.partitions)
        make_char_list(&ptr.qos_list, self._parse_qos())
        make_char_list(&ptr.state_list, self._parse_state())

        if self.nodelist:
            cstr.fmalloc(&ptr.used_nodes,
                         nodelist_to_range_str(self.nodelist))
            
        if self.ids:
            # These are only allowed by the slurmdbd when specific jobs are
            # requested.
            if self.with_script and self.with_env:
                raise ValueError("with_script and with_env are mutually "
                                 "exclusive")

            if self.with_script:
                ptr.flags |= slurm.JOBCOND_FLAG_SCRIPT
            elif self.with_env:
                ptr.flags |= slurm.JOBCOND_FLAG_ENV

            ptr.step_list = slurm_list_create(slurm_destroy_selected_step)
            already_added = []
            for i in self.ids:
                job_id = u32(i)
                if job_id in already_added:
                    continue

                selected_step = NULL
                selected_step = <slurm_selected_step_t*>try_xmalloc(
                        sizeof(slurm_selected_step_t))
                if not selected_step:
                    raise MemoryError("xmalloc failed for slurm_selected_step_t")

                selected_step.array_task_id = slurm.NO_VAL
                selected_step.het_job_offset = slurm.NO_VAL
                selected_step.step_id.step_id = slurm.NO_VAL
                selected_step.step_id.job_id = job_id
                slurm_list_append(ptr.step_list, selected_step)
                already_added.append(job_id)


cdef class Jobs(dict):

    def __init__(self):
        # TODO: ability to initialize with existing job objects
        pass

    @staticmethod
    def load(search_filter=None):
        """Load Jobs from the Slurm Database

        Implements the slurmdb_jobs_get RPC.

        Args:
            search_filter (pyslurm.db.JobSearchFilter):
                A search filter that the slurmdbd will apply when retrieving
                Jobs from the database.

        Raises:
            RPCError: When getting the Jobs from the Database was not
                sucessful

        Examples:
            Without a Filter the default behaviour applies, which is
            simply retrieving all Jobs from the same day:

            >>> import pyslurm
            >>> db_jobs = pyslurm.db.Jobs.load()

            Now with a Job Filter, so only Jobs that have specific Accounts
            are returned:

            >>> import pyslurm
            >>> accounts = ["acc1", "acc2"]
            >>> search_filter = pyslurm.db.JobSearchFilter(accounts=accounts)
            >>> db_jobs = pyslurm.db.Jobs.load(search_filter)
        """
        cdef:
            Jobs jobs = Jobs()
            Job job
            JobSearchFilter cond
            SlurmListItem job_ptr
            QualitiesOfService qos_data

        if search_filter:
            cond = <JobSearchFilter>search_filter
        else:
            cond = JobSearchFilter()

        cond._create()
        jobs.db_conn = Connection.open()
        jobs.info = SlurmList.wrap(slurmdb_jobs_get(jobs.db_conn.ptr,
                                                    cond.ptr))
        if jobs.info.is_null:
            raise RPCError(msg="Failed to get Jobs from slurmdbd")

        qos_data = QualitiesOfService.load(name_is_key=False,
                                           db_connection=jobs.db_conn)

        # TODO: also get trackable resources with slurmdb_tres_get and store
        # it in each job instance. tres_alloc_str and tres_req_str only
        # contain the numeric tres ids, but it probably makes more sense to
        # convert them to its type name for the user in advance.

        # TODO: For multi-cluster support, remove duplicate federation jobs
        # TODO: How to handle the possibility of duplicate job ids that could
        # appear if IDs on a cluster are resetted?
        for job_ptr in SlurmList.iter_and_pop(jobs.info):
            job = Job.from_ptr(<slurmdb_job_rec_t*>job_ptr.data)
            job.qos_data = qos_data
            job._create_steps()
            JobStatistics._sum_step_stats_for_job(job, job.steps)
            jobs[job.id] = job

        return jobs


cdef class Job:

    def __cinit__(self):
        self.ptr = NULL

    def __init__(self, job_id=0):
        self._alloc_impl()
        self.ptr.jobid = int(job_id)

    def __dealloc__(self):
        self._dealloc_impl()

    def _dealloc_impl(self):
        slurmdb_destroy_job_rec(self.ptr)
        self.ptr = NULL

    def _alloc_impl(self):
        if not self.ptr:
            self.ptr = <slurmdb_job_rec_t*>try_xmalloc(
                    sizeof(slurmdb_job_rec_t))
            if not self.ptr:
                raise MemoryError("xmalloc failed for slurmdb_job_rec_t")

    @staticmethod
    cdef Job from_ptr(slurmdb_job_rec_t *in_ptr):
        cdef Job wrap = Job.__new__(Job)
        wrap.ptr = in_ptr
        wrap.steps = JobSteps.__new__(JobSteps)
        wrap.stats = JobStatistics()
        return wrap

    @staticmethod
    def load(job_id, with_script=False, with_env=False):
        """Load the information for a specific Job from the Database.

        Args:
            job_id (int):
                ID of the Job to be loaded.

        Returns:
            (pyslurm.Job): Returns a new Database Job instance

        Raises:
            RPCError: If requesting the information for the database Job was
                not sucessful.

        Examples:
            >>> import pyslurm
            >>> db_job = pyslurm.db.Job.load(10000)

            In the above example, attribute like "script" and "environment"
            are not populated. You must explicitly request one of them to be
            loaded:

            >>> import pyslurm
            >>> db_job = pyslurm.db.Job.load(10000, with_script=True)
            >>> print(db_job.script)

        """
        jfilter = JobSearchFilter(ids=[int(job_id)],
                                  with_script=with_script, with_env=with_env)
        jobs = Jobs.load(jfilter)
        if not jobs or job_id not in jobs:
            raise RPCError(msg=f"Job {job_id} does not exist")

        return jobs[job_id]

    def _create_steps(self):
        cdef:
            JobStep step
            SlurmList step_list
            SlurmListItem step_ptr

        step_list = SlurmList.wrap(self.ptr.steps, owned=False) 
        for step_ptr in SlurmList.iter_and_pop(step_list):
            step = JobStep.from_ptr(<slurmdb_step_rec_t*>step_ptr.data)
            self.steps[step.id] = step

    def as_dict(self):
        """Database Job information formatted as a dictionary.

        Returns:
            (dict): Database Job information as dict

        Examples:
            >>> import pyslurm
            >>> myjob = pyslurm.db.Job.load(10000)
            >>> myjob_dict = myjob.as_dict()
        """
        cdef dict out = instance_to_dict(self)

        if self.stats:
            out["stats"] = self.stats.as_dict()

        steps = out.pop("steps", {})
        out["steps"] = {}
        for step_id, step in steps.items():
            out["steps"][step_id] = step.as_dict() 

        return out

    @property
    def account(self):
        return cstr.to_unicode(self.ptr.account)

    @property
    def admin_comment(self):
        return cstr.to_unicode(self.ptr.admin_comment)

    @property
    def num_nodes(self):
        val = TrackableResources.find_count_in_str(self.ptr.tres_alloc_str, 
                                                   slurm.TRES_NODE)
        if val is not None:
            # Job is already running and has nodes allocated
            return val
        else:
            # Job is still pending, so we return the number of requested nodes
            # instead.
            val = TrackableResources.find_count_in_str(self.ptr.tres_req_str, 
                                                       slurm.TRES_NODE)
            return val

    @property
    def array_id(self):
        return u32_parse(self.ptr.array_job_id)

    @property
    def array_tasks_parallel(self):
        return u32_parse(self.ptr.array_max_tasks)

    @property
    def array_task_id(self):
        return u32_parse(self.ptr.array_task_id)

    @property
    def array_tasks_waiting(self):
        task_str = cstr.to_unicode(self.ptr.array_task_str)
        if not task_str:
            return None
        
        if "%" in task_str:
            # We don't want this % character and everything after it
            # in here, so remove it.
            task_str = task_str[:task_str.rindex("%")]

        return task_str

    @property
    def association_id(self):
        return u32_parse(self.ptr.associd)

    @property
    def block_id(self):
        return cstr.to_unicode(self.ptr.blockid)

    @property
    def cluster(self):
        return cstr.to_unicode(self.ptr.cluster)

    @property
    def constraints(self):
        return cstr.to_list(self.ptr.constraints)

    @property
    def container(self):
        return cstr.to_list(self.ptr.container)

    @property
    def db_index(self):
        return u64_parse(self.ptr.db_index)

    @property
    def derived_exit_code(self):
        if (self.ptr.derived_ec == slurm.NO_VAL
                or not WIFEXITED(self.ptr.derived_ec)):
            return None

        return WEXITSTATUS(self.ptr.derived_ec)

    @property
    def derived_exit_code_signal(self):
        if (self.ptr.derived_ec == slurm.NO_VAL
                or not WIFSIGNALED(self.ptr.derived_ec)): 
            return None

        return WTERMSIG(self.ptr.derived_ec)

    @property
    def comment(self):
        return cstr.to_unicode(self.ptr.derived_es)

    @property
    def elapsed_time(self):
        return _raw_time(self.ptr.elapsed)

    @property
    def eligible_time(self):
        return _raw_time(self.ptr.eligible)

    @property
    def end_time(self):
        return _raw_time(self.ptr.end)

    @property
    def exit_code(self):
        # TODO
        return 0

    @property
    def exit_code_signal(self):
        # TODO
        return 0

    # uint32_t flags

    def group_id(self):
        return u32_parse(self.ptr.gid, zero_is_noval=False)

    def group_name(self):
        return gid_to_name(self.ptr.gid)

    # uint32_t het_job_id
    # uint32_t het_job_offset

    @property
    def id(self):
        return self.ptr.jobid

    @property
    def name(self):
        return cstr.to_unicode(self.ptr.jobname)

    # uint32_t lft
    
    @property
    def mcs_label(self):
        return cstr.to_unicode(self.ptr.mcs_label)

    @property
    def nodelist(self):
        return cstr.to_unicode(self.ptr.nodes)

    @property
    def partition(self):
        return cstr.to_unicode(self.ptr.partition)

    @property
    def priority(self):
        return u32_parse(self.ptr.priority, zero_is_noval=False)

    @property
    def qos(self):
        _qos = self.qos_data.get(self.ptr.qosid, None)
        if _qos:
            return _qos.name
        else:
            return None

    @property
    def cpus(self):
        val = TrackableResources.find_count_in_str(self.ptr.tres_alloc_str, 
                                                   slurm.TRES_CPU)
        if val is not None:
            # Job is already running and has cpus allocated
            return val
        else:
            # Job is still pending, so we return the number of requested cpus
            # instead.
            return u32_parse(self.ptr.req_cpus)

    @property
    def memory(self):
        val = TrackableResources.find_count_in_str(self.ptr.tres_req_str, 
                                                   slurm.TRES_MEM)
        return val

    @property
    def reservation(self):
        return cstr.to_unicode(self.ptr.resv_name)

#    @property
#    def reservation_id(self):
#        return u32_parse(self.ptr.resvid)

    @property
    def script(self):
        return cstr.to_unicode(self.ptr.script)

    @property
    def environment(self):
        return cstr.to_dict(self.ptr.env, delim1="\n", delim2="=")

    @property
    def start_time(self):
        return _raw_time(self.ptr.start)

    @property
    def state(self):
        return cstr.to_unicode(slurm_job_state_string(self.ptr.state))

    @property
    def state_reason(self):
        return cstr.to_unicode(slurm_job_reason_string
                               (self.ptr.state_reason_prev))

    @property
    def cancelled_by(self):
        return uid_to_name(self.ptr.requid)

    @property
    def submit_time(self):
        return _raw_time(self.ptr.submit)

    @property
    def submit_command(self):
        return cstr.to_unicode(self.ptr.submit_line)

    @property
    def suspended_time(self):
        return _raw_time(self.ptr.elapsed)

    @property
    def system_comment(self):
        return cstr.to_unicode(self.ptr.system_comment)

    @property
    def time_limit(self):
        # TODO: Perhaps we should just find out what the actual PartitionLimit
        # is?
        return _raw_time(self.ptr.timelimit, "PartitionLimit")

    @property
    def user_id(self):
        return u32_parse(self.ptr.uid, zero_is_noval=False)

    @property
    def user_name(self):
        # Theres also a ptr->user
        # https://github.com/SchedMD/slurm/blob/6365a8b7c9480c48678eeedef99864d8d3b6a6b5/src/sacct/print.c#L1946
        return uid_to_name(self.ptr.uid)

    # TODO: used gres

    @property
    def wckey(self):
        return cstr.to_unicode(self.ptr.wckey)

#    @property
#    def wckey_id(self):
#        return u32_parse(self.ptr.wckeyid)

    @property
    def working_directory(self):
        return cstr.to_unicode(self.ptr.work_dir)

#    @property
#    def tres_allocated(self):
#        return TrackableResources.from_str(self.ptr.tres_alloc_str)

#    @property
#    def tres_requested(self):
#        return TrackableResources.from_str(self.ptr.tres_req_str)
