#include "duckdb.hpp"
#include "duckdb/main/client_context.hpp"
#include "duckdb/parser/parser.hpp"
#include "duckdb/planner/planner.hpp"
#include "duckdb/optimizer/optimizer.hpp"
#include "duckdb/planner/logical_operator.hpp"
#include "duckdb/planner/operator/logical_get.hpp"
#include "duckdb/planner/operator/logical_comparison_join.hpp"
#include "duckdb/catalog/catalog_entry/table_catalog_entry.hpp"
#include "duckdb/planner/table_filter.hpp"
#include "duckdb/parser/expression/constant_expression.hpp"
#include "duckdb/common/enums/expression_type.hpp"
#include "duckdb/planner/table_filter.hpp"
#include "duckdb/planner/table_filter.hpp"
#include "duckdb/planner/filter/constant_filter.hpp"
#include "duckdb/planner/filter/null_filter.hpp"
#include "duckdb/planner/filter/conjunction_filter.hpp"
#include "duckdb/planner/operator/logical_order.hpp"
#include "duckdb/execution/executor.hpp"

#include "duckdb/common/common.hpp"
#include "duckdb/common/enums/pending_execution_result.hpp"
#include "duckdb/common/mutex.hpp"
#include "duckdb/common/reference_map.hpp"
#include "duckdb/main/query_result.hpp"
#include "duckdb/execution/task_error_manager.hpp"
#include "duckdb/execution/progress_data.hpp"
#include "duckdb/parallel/pipeline.hpp"
#include "duckdb/execution/column_binding_resolver.hpp"

#include <iostream>
#include <cuda_runtime.h>
#include <cuda.h>

#include "./kernels/agg.cuh"
#include "./kernels/get.cuh"
#include "./kernels/project.cuh"
#include "./kernels/sort.cuh"
#include "./kernels/join.cuh"
#include "./kernels/join.cuh"

#include "./utilities/schema_utilities.hpp"
#include "./utilities/filter_utilities.hpp"
#include "./utilities/join_utilities.hpp"
#include "./utilities/join_utilities.hpp"

#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>
#include <regex>
#include <cfloat>
using namespace std;
using namespace duckdb;

int RAM = 50 * pow(1024, 2); // 4GB
Schema schema;

struct PlanNode
{
    std::string name;
    std::vector<std::string> details; // e.g., filters, expressions
    std::vector<std::shared_ptr<PlanNode>> children;
};

struct return_node_type
{
    std::vector<char> data;
    std::vector<ColumnInfo> data_schema;
    int num_row;
};

return_node_type post_order_traverse_and_launch_kernel(std::shared_ptr<PlanNode> node)
{
    if (!node)
        return {};

    // 1. Traverse children first (post-order)
    std::vector<return_node_type> child_results;
    for (auto &child : node->children)
    {
        return_node_type data = post_order_traverse_and_launch_kernel(child);
        child_results.push_back(data);
    }

    // 2. Process current node (e.g., launch kernel)

    if (child_results.size() != 0 && child_results[0].num_row == 0)
    {
        return child_results[0];
    }
    // You can decide which CUDA kernel to call based on node->name
    if (node->name == "GET")
    {
        string table_name = node->details[0];
        int row_size;
        return_node_type return_data;
        return_data.data = std::vector<char>();
        return_data.num_row = 0;
        // 0.5 * RAM
        std::vector<char> chunk = read_csv_chunk(table_name, RAM, row_size);
        while (chunk.size() != 0)
        {
            if (node->details.size() > 1)
            {

                // std::vector<string> expr;
                // for (size_t i = 1; i < node->details.size(); ++i)
                // {
                //     expr.push_back(node->details[i]);
                //     if (i != node->details.size() - 1)
                //         expr.push_back("and");
                // }
                // int *acc_sums = new int[(schema[table_name].second.size())];
                // std::vector<Token> tokens = tokenize(expr);
                // std::vector<std::string> postfix = infix_to_postfix(tokens);
                // std::vector<ConditionToken> condition_tokens = parse_postfix(postfix, schema[table_name].second, acc_sums);
                // tokens.clear();
                // postfix.clear();
                // int n = chunk.size() / row_size;
                // int output_counter = 0;

                // char *data = call_get_kernel(chunk.data(), row_size, acc_sums, condition_tokens, condition_tokens.size(), n, output_counter, schema[table_name].second.size());

                // std::vector<char> vec_data(data, data + output_counter * row_size);
                // return_data.data.insert(return_data.data.end(), vec_data.begin(), vec_data.end());
                // vec_data.clear();
                // delete[] data;
                // return_data.num_row += output_counter;
                // return_data.data_schema = schema[table_name].second;
            }
            else
            {
                return_data.data.insert(return_data.data.end(), chunk.begin(), chunk.end());
                return_data.num_row += chunk.size() / row_size;
                return_data.data_schema = schema[table_name].second;
            }
            chunk.clear();
            chunk = read_csv_chunk(table_name, RAM, row_size);
        }
        chunk.clear();
        child_results.clear();
        return return_data;
        // launch_get_kernel();  // Your kernel logic here
    }
    else if (node->name == "FILTER")
    {
        if (node->details.size() == 0)
        {

            return child_results[0];
        }
        int row_size = child_results[0].data.size() / child_results[0].num_row;
        std::string expr = "";
        for (size_t i = 0; i < node->details.size(); ++i)
        {
            expr += node->details[i];
            if (i != node->details.size() - 1)
                expr += " and ";
        }
        std::string to_remove = "::TIMESTAMP";
        size_t pos;
        while ((pos = expr.find(to_remove)) != std::string::npos)
        {
            expr.erase(pos, to_remove.length());
        }
        expr = replace_operatirs(expr);
        int *acc_sums = new int[child_results[0].data_schema.size()];
        std::vector<std::string> vector_expr = tokenizeExpression(expr);

        std::vector<Token> tokens = tokenize(vector_expr);
        std::vector<std::string> postfix = infix_to_postfix(tokens);

        std::vector<ConditionToken> condition_tokens = parse_postfix(postfix, child_results[0].data_schema, acc_sums);
        return_node_type return_data;
        tokens.clear();
        postfix.clear();

        int output_counter = 0;
        int start = 0;
        int read_ram = (RAM / row_size) * row_size;
        int total_size = child_results[0].data.size();
        return_data.num_row = 0;
        return_data.data_schema = child_results[0].data_schema;

        while (start < total_size)
        {
            int end = min(start + read_ram, total_size);
            int num_row = (end - start) / row_size;

            // Create a  stream for each batch
            cudaStream_t batch_stream;
            cudaStreamCreate(&batch_stream);

            char *data = call_get_kernel(child_results[0].data.data() + start, row_size, acc_sums, condition_tokens, condition_tokens.size(), num_row, output_counter, child_results[0].data_schema.size(), batch_stream);

            //  Sync this stream only (non-blocking for others)
            cudaStreamSynchronize(batch_stream);
            cudaStreamDestroy(batch_stream); // Clean up

            std::vector<char> vec_data(data, data + output_counter * row_size);
            return_data.data.insert(return_data.data.end(), vec_data.begin(), vec_data.end());
            return_data.num_row += output_counter;
            vec_data.clear();
            delete[] data;
            start += read_ram;
        }
        child_results.clear();
        return return_data;
    }
    else if (node->name == "COMPARISON_JOIN")
    {
        // Determine which table is smaller by byte size
        int idx_a = 0;
        int idx_b = 1;

        // Prepare schemas and sizes
        int row_size_a = child_results[idx_a].data.size() / child_results[idx_a].num_row;
        int row_size_b = child_results[idx_b].data.size() / child_results[idx_b].num_row;
        
 


        
        // Get data and schema
        std::vector<ColumnInfo> schema_a = child_results[idx_a].data_schema;
        std::vector<ColumnInfo> schema_b = child_results[idx_b].data_schema;
        
        // Merge schema
        std::vector<ColumnInfo> schema_merged=schema_a;
        schema_merged.insert(schema_merged.end(), schema_b.begin(), schema_b.end());


        // Compute accumulated column sizes
        int accumulator = 0;
        for (int j = 0; j < schema_merged.size(); j++)
        {
            schema_merged[j].acc_col_size = accumulator;
            accumulator += schema_merged[j].size_in_bytes;
        }

        int *acc_sums_a = new int[child_results[idx_a].data_schema.size()];
        int *acc_sums_b = new int[child_results[idx_b].data_schema.size()];

        std::string expr = "";
        for (size_t i = 0; i < node->details.size(); ++i)
        {
            expr += "(" + node->details[i] + ")";
            if (i != node->details.size() - 1)
                expr += " and ";
        }

        expr = replace_operatirs(expr);
        std::vector<std::string> vector_expr = tokenizeExpression(expr);
        std::vector<Token> tokens = tokenize(vector_expr);
        std::vector<std::string> postfix = infix_to_postfix(tokens);


        std::vector<JoinConditionToken> condition_tokens = join_parse_postfix(postfix,child_results[idx_a].data_schema, child_results[idx_b].data_schema, acc_sums_a, acc_sums_b);


        // --------- Batching over table B ---------
        return_node_type return_data;

        int output_counter = 0;
        int start = 0;
        int read_ram = (RAM / row_size_b) * row_size_b;
        int total_size = child_results[idx_b].data.size();
        return_data.num_row = 0;
        return_data.data_schema = schema_merged;

        while (start < total_size)
        {
            int end = min(start + read_ram, total_size);
            int num_row = (end - start) / row_size_b;

            // Create a stream for each batch
            cudaStream_t batch_stream;
            cudaStreamCreate(&batch_stream);

            char *data = call_join_kernel(child_results[idx_a].data.data(), child_results[idx_a].num_row, row_size_a, acc_sums_a, child_results[idx_b].data.data() + start, num_row, row_size_b, acc_sums_b, output_counter, condition_tokens.data(), condition_tokens.size(), schema_a.size(), schema_b.size(), batch_stream);

            // Sync this stream only (non-blocking for others)
            cudaStreamSynchronize(batch_stream);
            cudaStreamDestroy(batch_stream); // Clean up
            std::vector<char> vec_data(data, data + output_counter * (row_size_a + row_size_b));
            return_data.data.insert(return_data.data.end(), vec_data.begin(), vec_data.end());
            return_data.num_row += output_counter;
            vec_data.clear();
            delete[] data;
            start += read_ram;
            
        }
        child_results.clear();
        return return_data;
    }
    
    else if (node->name == "ORDER_BY")
    {
        size_t lastDot = node->details[0].rfind('.');
        size_t lastSpace = node->details[0].rfind(' ');

        string col_name = node->details[0].substr(lastDot + 1, lastSpace - lastDot - 1);
        string oredr_method = node->details[0].substr(lastSpace + 1);

        int row_size = child_results[0].data.size() / child_results[0].num_row;
        int i = 0;
        while (child_results[0].data_schema[i].name != col_name)
        {
            i++;
        }
        int acc_sums = child_results[0].data_schema[i].acc_col_size;
        int start = 0;
        int total_size = child_results[0].data.size();
        int read_ram = (RAM / row_size) * row_size;
        char *data = call_sort_kernel(child_results[0].data.data(), row_size, child_results[0].num_row, acc_sums, (oredr_method == "ASC"));
        return_node_type return_data;
        return_data.data = std::vector<char>(data, data + child_results[0].num_row * row_size);
        return_data.num_row = child_results[0].num_row;
        return_data.data_schema = child_results[0].data_schema;
        child_results.clear();
        return return_data;
    }
    else if (node->name == "AGGREGATE")
    {

        int total_size = child_results[0].data.size();
        int row_size = total_size / child_results[0].num_row;
        int start = 0;
        int read_ram = (RAM / row_size) * row_size;
        int acc_col_size;
        int index;
        return_node_type return_data;
        return_data.num_row = 1;
        string col_name = node->details[0].substr(node->details[0].find("(") + 1, node->details[0].find(")") - node->details[0].find("(") - 1);
        char *op;
        double *final_result = NULL;
        double *curr_result = NULL;
        int num_batches = 0;

        while (start < total_size)
        {
            num_batches++;
            int end = min(start + read_ram, total_size);
            int num_row = (end - start) / row_size;
            if (start == 0)
            {
                for (int i = 0; i < child_results[0].data_schema.size(); i++)
                {
                    if (child_results[0].data_schema[i].name == col_name)
                    {
                        index = i;
                        acc_col_size = child_results[0].data_schema[i].acc_col_size;
                        break;
                    }
                }
            }

            if (node->details[0].find("max") != std::string::npos)
            {
                if (final_result == NULL)
                {
                    final_result = new double(-DBL_MAX);
                }
                if (curr_result != NULL)
                {
                    *final_result = max(*curr_result, *final_result);
                }
                op = "max";
            }
            else if (node->details[0].find("min") != std::string::npos)
            {
                if (final_result == NULL)
                {
                    final_result = new double(DBL_MAX);
                }
                if (curr_result != NULL)
                {
                    *final_result = min(*curr_result, *final_result);
                }
                op = "min";
            }
            else if (node->details[0].find("avg") != std::string::npos)
            {
                if (final_result == NULL)
                {
                    final_result = new double(0);
                }
                if (curr_result != NULL)
                {
                    *final_result += *curr_result;
                }
                op = "avg";
            }
            else if (node->details[0].find("sum") != std::string::npos)
            {
                if (final_result == NULL)
                {
                    final_result = new double(0);
                }
                if (curr_result != NULL)
                {
                    *final_result += *curr_result;
                }
                op = "sum";
            }
            else if (node->details[0].find("count_star()") != std::string::npos)
            {
                if (final_result == NULL)
                {
                    final_result = new double(0);
                }
                *final_result += num_row;
                op = "count_star";
            }
            else if (node->details[0].find("count") != std::string::npos)
            {
                if (final_result == NULL)
                {
                    final_result = new double(0);
                }
                if (curr_result != NULL)
                {
                    *final_result += *curr_result;
                }
                op = "count";
            }

            if (curr_result == NULL)
                curr_result = new double();
            *curr_result = call_agg_kernel(child_results[0].data.data() + start, row_size, acc_col_size, op, num_row);
            start += read_ram;
        }
        if (op == "avg")
        {
            *final_result += *curr_result;
            *final_result /= num_batches;
        }
        else if (op == "count")
        {
            *final_result = *curr_result;
        }
        else if (op == "sum")
        {
            *final_result += *curr_result;
        }
        else if (op == "min")
        {
            *final_result = min(*curr_result, *final_result);
        }
        else if (op == "max")
        {
            *final_result = max(*curr_result, *final_result);
        }

        const char *result_str = reinterpret_cast<const char *>(final_result);
        ColumnInfo col_info;
        col_info.type = child_results[0].data_schema[index].type;
        col_info.size_in_bytes = sizeof(double);
        col_info.acc_col_size = 0;
        col_info.name = node->details[0];
        if (op == "count_star" || op == "count")
        {
            col_info.type = "Numeric";
        }
        return_data.data_schema.push_back(col_info);
        return_data.data = std::vector<char>(result_str, result_str + sizeof(double));
        return return_data;
    }
    else if (node->name == "PROJECTION")
    {
        int total_size = child_results[0].data.size();
        int row_size = total_size / child_results[0].num_row;
        int start = 0;
        int read_ram = (RAM / row_size) * row_size;
        return_node_type return_data;
        int new_row_size = 0;
        int acc = 0;
        std::vector<ColumnInfo> child_schema = child_results[0].data_schema;
        int *acc_sums = new int[node->details.size()];
        int *col_index = new int[node->details.size()];
        int *sizes = new int[node->details.size()];
        std::vector<ColumnInfo> new_schema;

        return_data.data = std::vector<char>();
        return_data.num_row = child_results[0].num_row;

        while (start < total_size)
        {
            int end = min(start + read_ram, total_size);

            if (start == 0)
            {
                for (int i = 0; i < node->details.size(); i++)
                {
                    std::string col_name = node->details[i];
                    for (int j = 0; j < child_results[0].data_schema.size(); j++)
                    {
                        if (child_results[0].data_schema[j].name == col_name)
                        {
                            ColumnInfo col_info = child_results[0].data_schema[j];
                            col_info.acc_col_size = acc;
                            acc += child_results[0].data_schema[j].size_in_bytes;
                            new_schema.push_back(col_info);
                            col_index[i] = j;
                            acc_sums[i] = child_results[0].data_schema[j].acc_col_size;
                            sizes[i] = child_results[0].data_schema[j].size_in_bytes;
                            new_row_size += child_results[0].data_schema[j].size_in_bytes;
                            break;
                        }
                    }
                }
                return_data.data_schema = new_schema;
            }

            int num_row = (end - start) / row_size;

            char *data = call_project_kernel(child_results[0].data.data() + start, new_row_size, row_size, col_index, acc_sums, num_row, node->details.size(), sizes);

            return_data.data.insert(return_data.data.end(), data, data + num_row * new_row_size);
            start += read_ram;
        }
        child_results.clear();
        return return_data;
    }
    else
    {
        return child_results[0]; // Return the first child's result as a fallback
    }
}

std::shared_ptr<PlanNode> build_plan_tree(LogicalOperator *op)
{
    if (!op)
        return nullptr;

    auto node = std::make_shared<PlanNode>();
    node->name = LogicalOperatorToString(op->type);

    ColumnBindingResolver res;
    res.VisitOperator(*op);
    // Handle LogicalGet
    if (auto get_op = dynamic_cast<duckdb::LogicalGet *>(op))
    {

        if (get_op->GetTable())
        {
            node->details.push_back(get_op->GetTable()->name);
        }
        for (auto &[col_idx, filter] : get_op->table_filters.filters)
        {
            std::ostringstream oss;
            oss << get_op->names[col_idx] << " ";
            switch (filter->filter_type)
            {
            case duckdb::TableFilterType::CONSTANT_COMPARISON:
            {
                auto &f = static_cast<duckdb::ConstantFilter &>(*filter);
                std::string constant_str = f.constant.ToString();
                if (f.constant.type().id() == duckdb::LogicalTypeId::VARCHAR &&
                    constant_str.front() != '\'' && constant_str.back() != '\'')
                {
                    constant_str = "'" + constant_str + "'";
                }
                oss << ExpressionTypeToString(f.comparison_type) << " " << constant_str;
                break;
            }
            case duckdb::TableFilterType::IS_NULL:
                oss << "IS NULL";
                break;
            case duckdb::TableFilterType::IS_NOT_NULL:
                oss << "IS NOT NULL";
                break;
            case duckdb::TableFilterType::CONJUNCTION_AND:
                oss << "AND";
                break;
            case duckdb::TableFilterType::CONJUNCTION_OR:
                oss << "OR";
                break;
            default:
                oss << "UNKNOWN";
                break;
            }
            node->details.push_back(oss.str());
        }
    }

    // Handle LogicalComparisonJoin
    if (op->type == LogicalOperatorType::LOGICAL_COMPARISON_JOIN)
    {
        auto &join_op = static_cast<duckdb::LogicalComparisonJoin &>(*op);
        for (auto &condition : join_op.conditions)
        {
            node->details.push_back(condition.left->ToString() + " " + ExpressionTypeToString(condition.comparison) + " " + condition.right->ToString());
        }
    }

    // Handle LogicalOrder
    if (op->type == LogicalOperatorType::LOGICAL_ORDER_BY)
    {
        auto &order_by_op = static_cast<duckdb::LogicalOrder &>(*op);
        for (auto &order : order_by_op.orders)
        {
            std::string order_str = "Order By: " + order.expression->ToString();
            order_str += (order.type == duckdb::OrderType::ASCENDING) ? " ASC" : " DESC";
            node->details.push_back(order_str);
        }
    }

    for (auto &expr : op->expressions)
    {
        node->details.push_back(expr->ToString());
    }

    // Recurse on children
    for (auto &child : op->children)
    {
        node->children.push_back(build_plan_tree(child.get()));
    }

    return node;
}

void print_tree(std::shared_ptr<PlanNode> node, int indent = 0)
{
    if (!node)
        return;
    std::cout << std::string(indent, ' ') << "- " << node->name << std::endl;
    for (const auto &detail : node->details)
    {
        std::cout << std::string(indent + 2, ' ') << "* " << detail << std::endl;
    }
    for (const auto &child : node->children)
    {
        print_tree(child, indent + 4);
    }
}

std::unordered_map<std::string, std::string> remove_AS(string &query)
{
    std::unordered_map<std::string, std::string> alias_map;

    std::regex alias_pattern(R"(\b(\w+)\s+AS\s+(\w+))", std::regex::icase);
    std::smatch match;
    std::string::const_iterator searchStart(query.cbegin());

    while (std::regex_search(searchStart, query.cend(), match, alias_pattern))
    {
        std::string original = match[1];
        std::string alias = match[2];
        alias_map[original] = alias;
        searchStart = match.suffix().first;
    }

    for (const auto &pair : alias_map)
    {
        std::string pattern = "\\b" + pair.second + "\\b";
        query = std::regex_replace(query, std::regex(pattern), pair.first);
    }

    return alias_map;
}

int main(int argc, char *argv[])
{
    // DuckDB
    using namespace duckdb;
    DuckDB db(nullptr);
    Connection con(db);
    ClientContext &context = *con.context;
    con.Query("SET disabled_optimizers='filter_pushdown,statistics_propagation';");

    while (true)
    {
        cout << "\nEnter SQL query (or type 'exit' to quit): ";
        string query;
        getline(cin, query);

        if (query == "exit" || query == "quit")
        {
            cout << "Exiting CLI.\n";
            break;
        }

        std::unordered_map<std::string, std::string> alias_map = remove_AS(query);
        auto start = std::chrono::high_resolution_clock::now();
        get_schema(schema);

        create_tables_from_schema(con, schema);

        Parser parser;
        parser.ParseQuery(query);
        auto statements = std::move(parser.statements);
        // Start a transaction
        con.BeginTransaction(); // Start transaction using Connection

        // Create a planner and plan the query
        Planner planner(context);
        planner.CreatePlan(std::move(statements[0]));

        // Now you can proceed with further processing or optimization
        // cout << "Planning successful!" << endl;
        // cout << "Unoptimized Logical Plan:\n"
        //      << planner.plan->ToString() << endl;

        Optimizer optimizer(*planner.binder, context);
        auto logical_plan = optimizer.Optimize(std::move(planner.plan));
        // cout << "Optimized Logical Plan:\n";
        // cout << logical_plan->ToString() << endl;

        auto tree_root = build_plan_tree(logical_plan.get());
        print_tree(tree_root);

        return_node_type data_out = post_order_traverse_and_launch_kernel(tree_root);

        auto end = std::chrono::high_resolution_clock::now();

        std::chrono::duration<double> duration = end - start;

        std::cout << "Query execution time on GPU : " << duration.count() << " seconds" << std::endl;

        // print_chunk(data_out.data, data_out.data_schema,  std::unordered_map<std::string, std::string>());
        write_csv("output.csv", data_out.data, data_out.data_schema, alias_map);

        con.Commit(); // Commit transaction using Connection
    }
}