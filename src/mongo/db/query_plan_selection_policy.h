/**
 *    Copyright (C) 2011 10gen Inc.
 *
 *    This program is free software: you can redistribute it and/or  modify
 *    it under the terms of the GNU Affero General Public License, version 3,
 *    as published by the Free Software Foundation.
 *
 *    This program is distributed in the hope that it will be useful,
 *    but WITHOUT ANY WARRANTY; without even the implied warranty of
 *    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *    GNU Affero General Public License for more details.
 *
 *    You should have received a copy of the GNU Affero General Public License
 *    along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#pragma once

#include "mongo/db/jsobj.h"

namespace mongo {
    
    class QueryPlan;
    
    /**
     * An interface for policies overriding the query optimizer's default behavior for selecting
     * query plans and creating cursors.
     */
    class QueryPlanSelectionPolicy {
    public:
        virtual ~QueryPlanSelectionPolicy() {}
        virtual string name() const = 0;
        virtual bool permitOptimalNaturalPlan() const { return true; }
        virtual bool permitPlan( const QueryPlan& plan ) const { return true; }
        virtual BSONObj planHint( const StringData& ns ) const { return BSONObj(); }

        /**
         * @return true to request that a created Cursor provide a matcher().  If false, the
         * Cursor's matcher() may be NULL if the Cursor can perform accurate query matching
         * internally using a non Matcher mechanism.  One case where a Matcher might be requested
         * even though not strictly necessary to select matching documents is if metadata about
         * matches may be requested using MatchDetails.  NOTE This is a hint that the Cursor use a
         * Matcher, but the hint may be ignored.  In some cases the Cursor may not provide
         * a Matcher even if 'requestMatcher' is true.
         */
        virtual bool requestMatcher() const { return true; }

        /**
         * @return true to request a cursor optimized for counts.  Does not provide valid
         * results for currPK(), currKey(), or current(), because the internals are optimized
         * for counting index rows, not interpretting them.  As such, cannot be used on
         * multikey indexes for which manual deduplication is required.
         */
        virtual bool requestCountingCursor() const { return false; }

        /** Allow any query plan selection, permitting the query optimizer's default behavior. */
        static const QueryPlanSelectionPolicy& any();

        /** Prevent unindexed collection scans. */
        static const QueryPlanSelectionPolicy& indexOnly();
        
    private:
        class Any;
        static Any __any;
        class IndexOnly;
        static IndexOnly __indexOnly;
    };

    class QueryPlanSelectionPolicy::Any : public QueryPlanSelectionPolicy {
    public:
        virtual string name() const { return "any"; }
    };
    
    class QueryPlanSelectionPolicy::IndexOnly : public QueryPlanSelectionPolicy {
    public:
        virtual string name() const { return "indexOnly"; }
        virtual bool permitOptimalNaturalPlan() const { return false; }
        virtual bool permitPlan( const QueryPlan& plan ) const;
    };

} // namespace mongo
